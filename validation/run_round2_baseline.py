#!/usr/bin/env python3
"""Run unchanged regression tests against GestaltX's pre-round-two sources.

Requires macOS/Xcode and a checkout containing the baseline and test commits.
No working-tree production files are used. Compilation failure, timeout,
unexpected success, or a different runtime failure makes the script fail.

Example:
  python3 audit/run_round2_baseline.py --repo . \
      --tests-ref origin/r2/all-integration --output-dir "$RUNNER_TEMP/baseline"

The six tests use existing baseline APIs. H is deliberately excluded because
its fault-injection initializer parameter does not exist in the baseline.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time


BASELINE = "c6c22fc44da67e5c22e6fd7cf00a1cece4b4376d"
RUN_TIMEOUT = 90
COMPILE_TIMEOUT = 180
CORE = [
    "GestaltX/Capabilities.swift",
    "GestaltX/MobileGestaltCacheLayout.swift",
    "GestaltX/DeviceCacheOptions.swift",
    "GestaltX/GestaltDocument.swift",
]
CASES = [
    {
        "id": "A",
        "branch": "r2/reset-restored-local-provenance",
        "ref": "cc8de572bcad7c6b6557a8fe41eb66823025c227",
        "test": "tests/LocalRestoreProvenanceTests.swift",
        "sources": CORE,
        "error_type": "Failure(message:",
        "expected": "A replacement backup must not inherit the previous import's device ownership",
        "failure_point": "The restored local backup still carries ownershipVerified from the previous import.",
    },
    {
        "id": "D",
        "branch": "r2/preserve-device-identity-fields",
        "ref": "223b06712e985a786bd25755719601914d3f7c12",
        "test": "tests/DeviceIdentityEditTests.swift",
        "sources": CORE,
        "error_type": "Failure(message:",
        "expected": "A device identity edit was accepted: SerialNumber",
        "failure_point": "The first identity-removal fixture reaches a successful device commit.",
    },
    {
        "id": "G",
        "branch": "r2/skip-unchanged-device-restores",
        "ref": "c86ae82c3358d1a0c338c337d575613599cf5a2d",
        "test": "tests/UnchangedRestoreTests.swift",
        "sources": CORE,
        "error_type": "Failure(message:",
        "expected": "Restoring identical values must not write the device",
        "failure_point": "An identical restore invokes the injected real-file writer.",
    },
    {
        "id": "E",
        "branch": "r2/compare-nan-plist-values",
        "ref": "f4bd640baf332c1ae151c6e2954257cf93b87a1e",
        "test": "tests/NonFinitePlistTests.swift",
        "sources": CORE + ["Shared/SharedPlistInbox.swift", "GestaltX/DeviceBoundPlist.swift"],
        "error_type": "Failure(message:",
        "expected": "A valid plist containing NaN must compare equal to itself",
        "failure_point": "A Foundation-parsed NaN document fails reflexive comparison.",
    },
    {
        "id": "C",
        "branch": "r2/complete-original-history-migration",
        "ref": "905531d348a4b4e99dc5055ee63011c999e0c2fb",
        "test": "tests/OriginalHistoryMigrationTests.swift",
        "sources": CORE,
        "error_type": "GestaltFailure(key:",
        "expected": "The backup could not be verified. No system write was started.",
        "failure_point": "Reopening a complete field journal rereads its deliberately truncated old backup and throws before returning the snapshot.",
    },
    {
        "id": "B",
        "branch": "r2/scope-originals-to-cache-generation",
        "ref": "62e56738dbd941323b5b505581a5c8d5b6bb0083",
        "test": "tests/OriginalCacheGenerationTests.swift",
        "sources": CORE,
        "error_type": "GestaltFailure(key:",
        "expected": "The cache layout or values do not match this preset.",
        "failure_point": "The first matching-history fixture keeps the old cache original, so originalCachedOptionFlags throws instead of returning the matching backup's flags.",
    },
]


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


def export_blob(repo: Path, ref: str, relative: str, destination: Path) -> dict:
    data = git(repo, "show", f"{ref}:{relative}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return {"path": relative, "commit": ref,
            "blob": git(repo, "rev-parse", f"{ref}:{relative}").decode().strip(),
            "sha256": hashlib.sha256(data).hexdigest()}


def execute(command: list[str], timeout: int, directory: Path, label: str) -> dict:
    """Capture this invocation only and kill its entire process group on timeout."""
    start = time.monotonic()
    process = subprocess.Popen(command, cwd=directory, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
    elapsed = time.monotonic() - start
    out = stdout.decode("utf-8", errors="replace")
    err = stderr.decode("utf-8", errors="replace")
    (directory / f"{label}.stdout.log").write_text(out)
    (directory / f"{label}.stderr.log").write_text(err)
    result = {"command": command, "returncode": process.returncode,
              "elapsed_seconds": elapsed, "timed_out": timed_out}
    (directory / f"{label}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result | {"output": out + "\n" + err}


def run_case(repo: Path, baseline: str, tests_ref: str | None, swiftc: str,
             output: Path, case: dict) -> dict:
    directory = output / case["id"]
    directory.mkdir()
    test_ref = git(repo, "rev-parse", "--verify", f"{tests_ref or case['ref']}^{{commit}}").decode().strip()
    sources = []
    provenance = []
    for relative in case["sources"]:
        destination = directory / "baseline" / relative
        provenance.append(export_blob(repo, baseline, relative, destination))
        sources.append(str(destination))
    test_path = directory / "regression" / case["test"]
    test_provenance = export_blob(repo, test_ref, case["test"], test_path)
    (directory / "provenance.json").write_text(json.dumps({
        "production": provenance, "test": test_provenance,
        "expected_failure": case["expected"], "failure_point": case["failure_point"],
    }, indent=2) + "\n")
    binary = directory / f"Baseline_{case['id']}"
    command = [swiftc, "-parse-as-library", "-g", "-Onone", *sources, str(test_path), "-o", str(binary)]
    print(f"[{case['id']}] Compiling {case['test']} from {test_ref} with production {baseline}", flush=True)
    compiled = execute(command, COMPILE_TIMEOUT, directory, "compile")
    result = {"id": case["id"], "branch": case["branch"], "test_commit": test_ref,
              "baseline": baseline, "logs": str(directory), "expected": case["expected"]}
    if compiled["timed_out"] or compiled["returncode"] != 0:
        print(f"[{case['id']}] INVALID: compilation did not succeed; this is not a reproduction.", flush=True)
        print(compiled["output"][:20000], flush=True)
        return result | {"status": "compile_failed", "compile": {k: v for k, v in compiled.items() if k != "output"}}

    print(f"[{case['id']}] Compilation succeeded; running with a hard {RUN_TIMEOUT}s limit.", flush=True)
    ran = execute([str(binary)], RUN_TIMEOUT, directory, "run")
    # Require the expected Swift top-level failure, rather than accepting a
    # generic nonzero exit, a loader error, or text from compilation diagnostics.
    pattern = re.compile(r"Error raised at top level: .*" + re.escape(case["error_type"]) +
                         r'\s*"' + re.escape(case["expected"]) + r'"')
    matched = next((line for line in ran["output"].splitlines() if pattern.search(line)), None)
    if ran["timed_out"] or ran["elapsed_seconds"] >= RUN_TIMEOUT:
        status = "run_timed_out"
    elif ran["returncode"] == 0:
        status = "unexpected_pass"
    elif not matched:
        status = "unexpected_failure"
    else:
        status = "reproduced"
    print(f"[{case['id']}] {status.upper()}: exit={ran['returncode']}, elapsed={ran['elapsed_seconds']:.3f}s", flush=True)
    if matched:
        print(f"[{case['id']}] Expected regression: {matched}", flush=True)
    else:
        print(ran["output"][:20000], flush=True)
    return result | {"status": status, "matched_failure": matched,
                     "run": {k: v for k, v in ran.items() if k != "output"}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--output-dir", type=Path, default=Path("audit/round2-baseline-results"))
    parser.add_argument("--tests-ref", help="Read all tests from this integration commit/ref instead of their pinned individual commits")
    parser.add_argument("--case", action="append", choices=[case["id"] for case in CASES], dest="cases")
    parser.add_argument("--list", action="store_true", help="Print the exact case mapping without compiling")
    args = parser.parse_args()
    selected = [case for case in CASES if args.cases is None or case["id"] in args.cases]
    if args.list:
        print(json.dumps({"baseline": BASELINE, "runtime_limit_seconds": RUN_TIMEOUT,
                          "cases": selected}, indent=2))
        return 0
    swiftc = shutil.which("swiftc")
    if not swiftc:
        parser.error("swiftc is required; run this script on the macOS/Xcode validation runner")
    repo = args.repo.resolve()
    baseline = git(repo, "rev-parse", "--verify", f"{BASELINE}^{{commit}}").decode().strip()
    if baseline != BASELINE:
        raise RuntimeError("Unexpected baseline commit resolution")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=args.output_dir.resolve()))
    # Expected Swift fatal errors should not leave large core files in artifacts.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    print(f"Output: {output}", flush=True)
    print("Production sources are exported directly from " + baseline, flush=True)
    results = []
    for case in selected:
        try:
            results.append(run_case(repo, baseline, args.tests_ref, swiftc, output, case))
        except Exception as error:
            print(f"[{case['id']}] SETUP FAILED: {error}", file=sys.stderr, flush=True)
            results.append({"id": case["id"], "status": "setup_failed", "error": str(error)})
    summary = {"baseline": baseline, "created_utc": datetime.now(timezone.utc).isoformat(),
               "cases": results, "all_reproduced": all(item["status"] == "reproduced" for item in results)}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("\n" + json.dumps(summary, indent=2), flush=True)
    print("Full source provenance and compiler/runtime logs: " + str(output), flush=True)
    return 0 if summary["all_reproduced"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
