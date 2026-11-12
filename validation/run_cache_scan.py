#!/usr/bin/env python3
"""Compile unchanged regressions against original and revised production sources."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys


CORE = [
    "GestaltX/Capabilities.swift",
    "GestaltX/MobileGestaltCacheLayout.swift",
    "GestaltX/DeviceCacheOptions.swift",
    "GestaltX/GestaltDocument.swift",
]
REGRESSION = "tests/DateInputTests.swift"
EXPECTED = {
    "suffix": "A valid date prefix must not hide a trailing suffix",
    "second-value": "A date field must not silently discard a second value",
}
EXISTING = [
    "DocumentTests", "OriginalCacheGenerationTests", "BackupLayoutTests",
    "OriginalHistoryMigrationTests", "UnchangedRestoreTests",
    "LocalRestoreProvenanceTests", "DeviceIdentityEditTests", "SiriCapabilityTests", "FieldValuePrecisionTests",
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
    test, details = export(repo, test_ref, test_path, root / "regression")
    provenance.append(details)
    test_paths = [str(test)]
    if test_path == "tests/DocumentTests.swift":
        helper, details = export(repo, test_ref, "tests/WAPITests.swift", root / "regression")
        test_paths.append(str(helper))
        provenance.append(details)
    (root / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    binary = root / "test"
    compiled = run(["swiftc", "-swift-version", "5", "-parse-as-library", "-O", *paths,
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
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    fixed = git(repo, "rev-parse", "HEAD").decode().strip()
    binaries = {}
    summary = {"base": args.base, "head": fixed, "benchmarks": [], "compatibility": []}
    for label, ref in [("baseline", args.base), ("fixed", fixed)]:
        dest = output / label
        binaries[label] = compile_test(repo, ref, fixed, "tests/CacheScanWorkloads.swift", dest)
        result = run([binaries[label], "compat"], dest, "compat", 90)
        assert result["returncode"] == 0, result
        print(label, result["stdout"], flush=True)
        summary["compatibility"].append({"label": label, "output": result["stdout"]})
        test_root = output / (label + "-malformed")
        binary = compile_test(repo, ref, fixed, "tests/MalformedCacheDescriptorTests.swift", test_root)
        result = run([binary], test_root, "run", 90)
        assert result["returncode"] == 0, result
        print(label, result["stdout"], flush=True)
    for round_number in range(5):
        order = ["baseline", "fixed"] if round_number % 2 == 0 else ["fixed", "baseline"]
        for case in ["typical", "many-strings", "large-string-area"]:
            for label in order:
                dest = output / label
                result = run(["/usr/bin/time", "-l", binaries[label], case], dest, f"bench-{case}-{round_number}", 90)
                assert result["returncode"] == 0, result
                row = json.loads(result["stdout"])
                row.update(label=label, round=round_number, memory=result["stderr"])
                summary["benchmarks"].append(row)
                print(json.dumps(row), flush=True)
    root = output / "DocumentTests"
    binary = compile_test(repo, fixed, fixed, "tests/DocumentTests.swift", root)
    result = run([binary], root, "run", 90)
    assert result["returncode"] == 0, result
    print(result["stdout"], flush=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
