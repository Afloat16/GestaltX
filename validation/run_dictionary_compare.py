#!/usr/bin/env python3
"""Compile unchanged regressions against original and revised production sources."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import re
import statistics
import signal
import subprocess
import sys


CORE = [
    "GestaltX/Capabilities.swift",
    "GestaltX/MobileGestaltCacheLayout.swift",
    "GestaltX/DeviceCacheOptions.swift",
    "GestaltX/GestaltDocument.swift",
]
REGRESSION = "tests/DictionaryComparisonTests.swift"
EXISTING = [
    "DocumentTests", "OriginalCacheGenerationTests", "BackupLayoutTests",
    "OriginalHistoryMigrationTests", "UnchangedRestoreTests", "LocalRestoreProvenanceTests",
    "DeviceIdentityEditTests", "SiriCapabilityTests", "FieldValuePrecisionTests",
    "DynamicIslandRestorationTests", "ArtworkPreservationTests", "IntegerValueTests",
    "NonFinitePlistTests", "DevicePlistIdentityTests", "DeviceBoundPlistTests",
    "BackupExportProofTests", "BackupIntegrityTests",
]



def git(repo, *arguments):
    return subprocess.check_output(["git", "-C", str(repo), *arguments])


def export(repo, ref, path, root):
    data = git(repo, "show", f"{ref}:{path}")
    destination = root / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return destination, {"path": path, "commit": ref,
                         "blob": git(repo, "rev-parse", f"{ref}:{path}").decode().strip(),
                         "sha256": hashlib.sha256(data).hexdigest()}


def run(command, root, label, timeout):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        (root / f"{label}.stdout").write_bytes(stdout)
        (root / f"{label}.stderr").write_bytes(stderr)
        raise RuntimeError(f"{label} timed out; this is not a valid reproduction")
    (root / f"{label}.stdout").write_bytes(stdout)
    (root / f"{label}.stderr").write_bytes(stderr)
    return {"command": command, "returncode": process.returncode,
            "stdout": stdout.decode(errors="replace"), "stderr": stderr.decode(errors="replace")}


def compile_test(repo, source_ref, test_ref, test_path, root):
    root.mkdir(parents=True, exist_ok=True)
    paths, provenance = [], []
    for path in CORE:
        output, details = export(repo, source_ref, path, root / "production")
        paths.append(str(output))
        provenance.append(details)
    if test_path in {"tests/DevicePlistIdentityTests.swift", "tests/DeviceBoundPlistTests.swift", "tests/BackupExportProofTests.swift", "tests/NonFinitePlistTests.swift"}:
        for extra in ["Shared/SharedPlistInbox.swift", "GestaltX/DeviceBoundPlist.swift", "GestaltX/DevicePlistIdentity.swift"]:
            output, details = export(repo, source_ref, extra, root / "production")
            paths.append(str(output))
            provenance.append(details)
    test, details = export(repo, test_ref, test_path, root / "regression")
    provenance.append(details)
    test_paths = [str(test)]
    if test_path == "tests/DocumentTests.swift":
        helper, details = export(repo, test_ref, "tests/WAPITests.swift", root / "regression")
        test_paths.append(str(helper))
        provenance.append(details)
    (root / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    binary = root / "test"
    compiled = run(["swiftc", *(["-O"] if test_path == REGRESSION else []), "-swift-version", "5", "-parse-as-library", *paths,
                    *test_paths, "-o", str(binary)], root, "compile", 180)
    if compiled["returncode"] != 0:
        print(compiled["stderr"], flush=True)
        raise RuntimeError(f"Compilation failed for {source_ref} / {test_path}")
    print(f"COMPILED {source_ref} / {test_path}", flush=True)
    return str(binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--remaining-only", action="store_true")
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    base = git(repo, "rev-parse", args.base).decode().strip()
    fixed = git(repo, "rev-parse", "HEAD").decode().strip()
    summary = {"base": base, "fixed": fixed, "correctness": {}, "benchmarks": {}, "fixed_tests": []}
    try:
        if args.remaining_only:
            verified = "5703c9a0b00299beab510d9e2b4ab33536c1bed6"
            proof_paths = CORE + [REGRESSION, "Shared/SharedPlistInbox.swift", "GestaltX/DeviceBoundPlist.swift", "GestaltX/DevicePlistIdentity.swift"]
            for path in proof_paths:
                if git(repo, "rev-parse", f"{verified}:{path}") != git(repo, "rev-parse", f"{fixed}:{path}"):
                    raise RuntimeError("Previously verified blob changed: " + path)
            summary["reused_evidence"] = {
                "run": "https://github.com/Afloat16/GestaltX/actions/runs/43224939964",
                "source": verified, "identical_blobs": proof_paths,
                "coverage": "8 correctness cases, 176400 exact integer pairs, interleaved time/RSS measurements and 12 existing native regressions passed",
            }
            existing = EXISTING[12:]
        else:
            binaries = {}
            for label, ref in [("baseline", base), ("fixed", fixed)]:
                root = output / label
                binary = compile_test(repo, ref, fixed, REGRESSION, root)
                binaries[label] = binary
                result = run([binary, "correctness"], root, "correctness", 90)
                if result["returncode"] != 0:
                    raise RuntimeError(f"Correctness failure for {label}: {result}")
                summary["correctness"][label] = result["stdout"].strip()
                print(label + " " + result["stdout"], flush=True)
            for case in ["wide", "nested"]:
                timings = {"baseline": [], "fixed": []}
                memory = {"baseline": [], "fixed": []}
                for iteration in range(3):
                    order = ["baseline", "fixed"] if iteration % 2 == 0 else ["fixed", "baseline"]
                    for label in order:
                        root = output / label
                        result = run(["/usr/bin/time", "-l", binaries[label], case], root, f"{case}-{iteration}", 180)
                        if result["returncode"] != 0:
                            raise RuntimeError(f"Benchmark failed: {case} / {label}: {result}")
                        data = json.loads(result["stdout"])
                        timings[label].extend(data["samples_seconds"])
                        rss = re.search(r"(\d+)\s+maximum resident set size", result["stderr"])
                        if not rss:
                            raise RuntimeError("Native resident-size measurement missing")
                        memory[label].append(int(rss.group(1)))
                medians = {key: statistics.median(value) for key, value in timings.items()}
                evidence = {"samples_seconds": timings, "median_seconds": medians,
                            "speedup": medians["baseline"] / medians["fixed"],
                            "peak_rss_native": memory, "median_peak_rss_native": {key: statistics.median(value) for key, value in memory.items()},
                            "comparisons_per_sample": 12}
                summary["benchmarks"][case] = evidence
                print("BENCHMARK " + case + " " + json.dumps(evidence), flush=True)
                if evidence["speedup"] < 1.05:
                    raise RuntimeError("Measured benefit is below the predeclared 5% threshold: " + case)
            existing = EXISTING
        for name in existing:
            root = output / name
            binary = compile_test(repo, fixed, fixed, f"tests/{name}.swift", root)
            result = run([binary], root, "run", 90)
            if result["returncode"] != 0:
                raise RuntimeError(f"Existing regression failed: {name}: {result}")
            print(result["stdout"], flush=True)
            summary["fixed_tests"].append({"test": name, "passed": True})
        summary["success"] = True
    except Exception as error:
        summary["success"] = False
        summary["error"] = str(error)
        print(str(error), file=sys.stderr, flush=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
