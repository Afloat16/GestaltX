#!/usr/bin/env python3
"""Check the ten contribution patches together with native macOS regressions.

This validation-only branch records combined compatibility. It does not publish
another contribution or replace each independent patch's original comparison.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


CORE = ["GestaltX/Capabilities.swift", "GestaltX/MobileGestaltCacheLayout.swift",
        "GestaltX/DeviceCacheOptions.swift", "GestaltX/GestaltDocument.swift"]
EXTRA = ["Shared/SharedPlistInbox.swift", "GestaltX/DeviceBoundPlist.swift",
         "GestaltX/DevicePlistIdentity.swift"]
EXISTING = [
    "DocumentTests", "OriginalCacheGenerationTests", "BackupLayoutTests",
    "OriginalHistoryMigrationTests", "UnchangedRestoreTests", "LocalRestoreProvenanceTests",
    "DeviceIdentityEditTests", "SiriCapabilityTests", "FieldValuePrecisionTests",
    "DynamicIslandRestorationTests", "ArtworkPreservationTests", "IntegerValueTests",
    "NonFinitePlistTests", "DevicePlistIdentityTests", "DeviceBoundPlistTests",
    "BackupExportProofTests", "BackupIntegrityTests", "BackupDeletionTests",
    "MalformedCacheDescriptorTests",
]


def run(command, output, label, repo, timeout=180):
    process = subprocess.Popen(list(map(str, command)), cwd=repo,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        (output / (label + ".stdout")).write_bytes(stdout)
        (output / (label + ".stderr")).write_bytes(stderr)
        raise RuntimeError(label + " timed out")
    (output / (label + ".stdout")).write_bytes(stdout)
    (output / (label + ".stderr")).write_bytes(stderr)
    if process.returncode:
        print(stderr.decode(errors="replace"), flush=True)
        raise RuntimeError(f"{label} exited {process.returncode}")
    print(label + ": " + stdout.decode(errors="replace").strip(), flush=True)
    return stdout.decode()


def load_helper(repo, name):
    spec = importlib.util.spec_from_file_location(name, repo / "tests" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary = {"head": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"]).decode().strip(),
               "new_regressions": [], "existing_regressions": [], "success": False}
    paths = subprocess.check_output(["git", "-C", str(repo), "diff", "--name-only",
                                     "6a8f94de9673460bb78548855a524817122d7752", "HEAD"]).decode().splitlines()
    provenance = [{"path": path, "sha256": hashlib.sha256((repo / path).read_bytes()).hexdigest(),
                   "blob": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD:" + path]).decode().strip()}
                  for path in paths]
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")

    def swift_test(name, arguments=(), core=CORE):
        destination = output / name
        destination.mkdir()
        sources = [repo / path for path in core]
        if name in {"NonFinitePlistTests", "DevicePlistIdentityTests", "DeviceBoundPlistTests", "BackupExportProofTests"}:
            sources += [repo / path for path in EXTRA]
        if name == "DocumentTests":
            sources.append(repo / "tests/WAPITests.swift")
        sources.append(repo / "tests" / (name + ".swift"))
        binary = destination / "test"
        # Keep assertions active in the existing regression programs. Only the
        # dictionary workload uses its verified explicit throwing checks with -O.
        options = ["-O"] if name == "DictionaryComparisonTests" else []
        run(["swiftc", *options, "-swift-version", "5", "-parse-as-library", *sources, "-o", binary],
            destination, "compile", repo)
        run([binary, *arguments], destination, "run", repo, timeout=90)

    try:
        # Current combined sources only: independent baseline and performance
        # measurements already live with the individual contribution receipts.
        for name, arguments in [("CacheUUIDCaseTests", []), ("DateInputTests", []),
                                ("BackupMetadataIdentityTests", []), ("CacheScanWorkloads", ["compat"]),
                                ("DictionaryComparisonTests", ["correctness"])]:
            swift_test(name, arguments)
            summary["new_regressions"].append(name)
        publication = load_helper(repo, "run_shared_publication")
        destination = output / "SharedInboxPublicationTests"
        binary = publication.compile_case(repo, "HEAD", "HEAD", destination)
        for case in ["bad-first", "two-bad", "linked-first", "first-healthy", "all-bad", "invalid", "empty", "cancelled"]:
            stdout = run([binary, case], destination, case, repo)
            if "PASS " + case not in stdout:
                raise RuntimeError("Missing publication case result: " + case)
        summary["new_regressions"].append("SharedInboxPublicationTests")
        search = load_helper(repo, "run_field_search")
        destination = output / "FieldSearchTests"
        binary = search.compile_case(repo, "HEAD", "HEAD", destination)
        stdout = run([binary], destination, "run", repo)
        if len(stdout.splitlines()) != 18 or not all(line.startswith("PASS ") for line in stdout.splitlines()):
            raise RuntimeError("Missing field search behavior cases")
        summary["new_regressions"].append("FieldSearchTests")
        # Exercise the exact documented default CLI, including default --case.
        for name, helper in [("FieldEditPrecedenceTests", "run_field_manager_regression"),
                             ("FieldKeyIdentityTests", "run_field_manager_regression"),
                             ("DocumentDiffTests", "run_document_diff_regression")]:
            destination = output / name
            destination.mkdir()
            stdout = run([sys.executable, "tests/" + helper + ".py", "--test", "tests/" + name + ".swift"],
                         destination, "default-cli", repo, timeout=240)
            if name == "DocumentDiffTests" and len(json.loads(stdout)) != 10:
                raise RuntimeError("Missing document diff output fixtures")
            summary["new_regressions"].append(name)
        for name in EXISTING:
            swift_test(name)
            summary["existing_regressions"].append(name)
        for name in ["SharedPlistInboxTests", "SharedInboxContainmentTests", "SharedInboxCleanupTests", "SharedMetadataNameTests"]:
            swift_test(name, core=["Shared/SharedPlistInbox.swift"])
            summary["existing_regressions"].append(name)
        summary["success"] = True
    except Exception as error:
        summary["error"] = str(error)
        print(str(error), file=sys.stderr, flush=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
