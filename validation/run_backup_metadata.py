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
REGRESSION = "tests/BackupMetadataIdentityTests.swift"
EXPECTED = {
    "duplicate": "Mismatched metadata must not duplicate another backup",
    "renamed-only": "A metadata alias must not offer operations against another backup ID",
    "non-uuid": "Unrecognized metadata names must not enter backup history",
}

EXISTING = [
    "DocumentTests", "OriginalCacheGenerationTests", "BackupLayoutTests",
    "OriginalHistoryMigrationTests", "UnchangedRestoreTests",
    "LocalRestoreProvenanceTests", "DeviceIdentityEditTests", "SiriCapabilityTests", "FieldValuePrecisionTests",
    "BackupIntegrityTests", "BackupDeletionTests", "BackupExportProofTests",
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
    compiled = run(["swiftc", "-swift-version", "5", "-parse-as-library", *paths,
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
    base = git(repo, "rev-parse", args.base).decode().strip()
    fixed = git(repo, "rev-parse", "HEAD").decode().strip()
    summary = {"base": base, "fixed": fixed, "baseline": [], "fixed_tests": []}
    try:
        binary = compile_test(repo, base, fixed, REGRESSION, output / "baseline")
        for case, expected in EXPECTED.items():
            result = run([binary, case], output / "baseline", case, 90)
            if result["returncode"] == 0 or expected not in result["stderr"]:
                raise RuntimeError(f"Expected baseline failure missing: {case}: {result}")
            summary["baseline"].append({"case": case, "expected": expected,
                                        "returncode": result["returncode"], "reproduced": True})
            print(f"BASELINE REPRODUCED {case}: {expected}", flush=True)
        binary = compile_test(repo, fixed, fixed, REGRESSION, output / "fixed")
        result = run([binary, "all"], output / "fixed", "run", 90)
        if result["returncode"] != 0:
            raise RuntimeError(f"Revised regressions failed: {result}")
        print(result["stdout"], flush=True)
        summary["fixed_tests"].append({"test": "BackupMetadataIdentityTests", "passed": True})
        for name in EXISTING:
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
