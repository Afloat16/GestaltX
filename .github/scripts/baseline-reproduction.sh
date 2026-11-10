#!/usr/bin/env bash
# Fork-only regression evidence. This script never checks out or edits a branch.
#
# Usage (macOS with Swift/Xcode and Python 3):
#   bash audit/baseline-reproduction.sh REPOSITORY OUTPUT_DIRECTORY
#
# Actions checkout must have fetch-depth: 0 and all five fix commits available.
# Defaults pin the reviewed upstream main and the five independent fix heads.
# Override GX_BASELINE_REF / GX_*_REF only when deliberately checking other refs.
# Set GX_RUN_FIXED=0 to omit fixed runs already covered by exact-SHA CI; omitted
# runs are not reported as passing. Upload OUTPUT_DIRECTORY as the evidence.
set -euo pipefail

repo="$(git -C "${1:-.}" rev-parse --show-toplevel)"
output="${2:-$repo/audit/baseline-results}"
baseline_ref="${GX_BASELINE_REF:-36110fd7544ceefdc419e13d337ec515e3ec53dc}"
integer_ref="${GX_INTEGER_REF:-5a661357c3b82d1588c9e6bc658cd4a844cec48a}"
layout_ref="${GX_LAYOUT_REF:-40041328d0b4501f4865a4ae60e165bed8058565}"
integrity_ref="${GX_INTEGRITY_REF:-a60714267a31d5c343838498928498a5e6e3e96e}"
artwork_ref="${GX_ARTWORK_REF:-9c58ffd2c44cf99232ff98ddae4fdb933bfdeb8e}"
regular_ref="${GX_REGULAR_REF:-3f6bae17429f009572fb647c5be1ca93679183cf}"
run_fixed="${GX_RUN_FIXED:-1}"
if [[ "$run_fixed" != 0 && "$run_fixed" != 1 ]]; then
  printf '%s\n' 'GX_RUN_FIXED must be 0 or 1.' >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'This harness requires macOS; a missing platform is not regression evidence.' >&2
  exit 2
fi
command -v swiftc >/dev/null
command -v python3 >/dev/null
mkdir -p "$output"
output="$(cd "$output" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gestaltx-baseline.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
ulimit -c 0 || true
: > "$output/results.jsonl"

resolve() { git -C "$repo" rev-parse --verify --end-of-options "$1^{commit}"; }
baseline_sha="$(resolve "$baseline_ref")"

source_paths=(
  GestaltX/GestaltDocument.swift
  GestaltX/Capabilities.swift
  GestaltX/DeviceCacheOptions.swift
  GestaltX/MobileGestaltCacheLayout.swift
  Shared/SharedPlistInbox.swift
)

materialize_sources() {
  local sha="$1"
  local destination="$scratch/source-$sha"
  if [[ ! -d "$destination" ]]; then
    mkdir -p "$destination"
    git -C "$repo" archive "$sha" -- "${source_paths[@]}" | tar -x -C "$destination"
  fi
  printf '%s\n' "$destination"
}

# The full IntegerValueTests compiles on main, but stops at the old parser's
# thrown validation error before its equality assertion. Use the same public
# production APIs in a small fixture with explicit, independent assertions so
# neither an arbitrary exception nor a compiler error can count as a failure.
cat > "$scratch/IntegerBoundaryReproduction.swift" <<'SWIFT'
import Foundation

@main struct IntegerBoundaryReproduction {
    struct Failure: Error { let message: String }
    static func main() throws {
        let mode = CommandLine.arguments[1]
        if mode == "parse" {
            guard let parsed = try? PlistValueKind.integer.parse("18446744073709551615"),
                  (parsed as? NSNumber)?.stringValue == "18446744073709551615" else {
                throw Failure(message: "Integer parser must preserve UInt64.max")
            }
        } else if mode == "compare" {
            guard !GestaltDocument.valuesEqual(NSNumber(value: UInt64.max), NSNumber(value: Int64(-1))) else {
                throw Failure(message: "Unsigned maximum must not alias signed -1")
            }
        } else {
            throw Failure(message: "Unknown integer reproduction mode")
        }
        print("PASS: integer \(mode) boundary regression.")
    }
}
SWIFT

run_checked() {
  local phase="$1" name="$2" source_sha="$3" test_sha="$4" executable="$5" marker="$6" argument="${7:-}"
  python3 - "$phase" "$name" "$source_sha" "$test_sha" "$executable" "$marker" "$argument" "$output" <<'PY'
import json
import hashlib
import pathlib
import subprocess
import sys
import time

phase, name, source_sha, test_sha, executable, marker, argument, output = sys.argv[1:]
destination = pathlib.Path(output)
log_path = destination / f"{phase}-{name}.run.log"
command = [executable] + ([argument] if argument else [])
started = time.monotonic()
try:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace", timeout=90)
except subprocess.TimeoutExpired as error:
    data = error.stdout or b""
    log_path.write_text(data.decode(errors="replace") if isinstance(data, bytes) else data)
    raise SystemExit(f"FAIL {phase}/{name}: timeout is not regression evidence; see {log_path}")
log_path.write_text(result.stdout)
if phase == "baseline":
    passed = result.returncode != 0 and marker in result.stdout
    verdict = "expected_assertion_failure"
else:
    passed = result.returncode == 0 and "PASS:" in result.stdout
    verdict = "pass"
if not passed:
    print(result.stdout[-16000:])
    raise SystemExit(f"FAIL {phase}/{name}: return code {result.returncode}; expected marker {marker!r}; see {log_path}")
fixture_name = "integers" if name.startswith("integer-") else name
fixture = destination / f"{fixture_name}.fixture.swift"
fixture_origin = "generated production-API boundary fixture" if fixture_name == "integers" else "unaltered test from reference fix commit"
evidence = dict(phase=phase, case=name, production_sha=source_sha, reference_fix_sha=test_sha,
                fixture_origin=fixture_origin, fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                verdict=verdict, expected_assertion=marker, returncode=result.returncode,
                elapsed_seconds=round(time.monotonic() - started, 3), log=str(log_path))
with (destination / "results.jsonl").open("a") as stream:
    stream.write(json.dumps(evidence) + "\n")
print(f"PASS {phase}/{name}: {verdict}; production={source_sha}")
PY
}

check_case() {
  local name="$1" fix_ref="$2" test_path="$3" marker="$4"
  local fix_sha test_source
  fix_sha="$(resolve "$fix_ref")"
  test_source="$scratch/$name.swift"
  if [[ "$name" == integers ]]; then
    cp "$scratch/IntegerBoundaryReproduction.swift" "$test_source"
    # Also retain the unmodified contributed test for inspectable provenance.
    git -C "$repo" show "$fix_sha:$test_path" > "$output/IntegerValueTests.contributed.swift"
  else
    git -C "$repo" show "$fix_sha:$test_path" > "$test_source"
  fi
  cp "$test_source" "$output/$name.fixture.swift"
  local phases=(baseline)
  if [[ "$run_fixed" == 1 ]]; then phases+=(fixed); fi
  local phase source_sha source_directory executable compile_log
  for phase in "${phases[@]}"; do
    source_sha="$baseline_sha"
    if [[ "$phase" == fixed ]]; then source_sha="$fix_sha"; fi
    source_directory="$(materialize_sources "$source_sha")"
    executable="$scratch/$phase-$name"
    compile_log="$output/$phase-$name.compile.log"
    local sources=()
    if [[ "$name" == regular-files ]]; then
      sources=("$source_directory/Shared/SharedPlistInbox.swift")
    else
      local path
      for path in "${source_paths[@]}"; do
        if [[ "$path" != Shared/SharedPlistInbox.swift ]]; then sources+=("$source_directory/$path"); fi
      done
    fi
    if ! swiftc -swift-version 5 -parse-as-library "${sources[@]}" "$test_source" -o "$executable" > "$compile_log" 2>&1; then
      tail -n 80 "$compile_log" >&2
      printf 'FAIL %s/%s: compilation failure is not regression evidence.\n' "$phase" "$name" >&2
      exit 1
    fi
    if [[ "$name" == integers ]]; then
      run_checked "$phase" integer-parse "$source_sha" "$fix_sha" "$executable" 'Integer parser must preserve UInt64.max' parse
      run_checked "$phase" integer-compare "$source_sha" "$fix_sha" "$executable" 'Unsigned maximum must not alias signed -1' compare
    else
      run_checked "$phase" "$name" "$source_sha" "$fix_sha" "$executable" "$marker"
    fi
  done
}

check_case integers "$integer_ref" tests/IntegerValueTests.swift 'Unused integer group marker'
check_case backup-layout "$layout_ref" tests/BackupLayoutTests.swift 'Incompatible same-device backup reached the writer'
check_case backup-integrity "$integrity_ref" tests/BackupIntegrityTests.swift 'Corrupt backup passed integrity checks'
check_case artwork "$artwork_ref" tests/ArtworkPreservationTests.swift 'Preserve malformed string artwork when editing ArtworkDeviceProductDescription'
# This test fails on symlinked metadata before creating a FIFO on the baseline.
# A hang or timeout can therefore never stand in for its expected assertion.
check_case regular-files "$regular_ref" tests/SharedPlistInboxTests.swift 'Ignore symlinked metadata instead of following it'

printf 'Completed baseline regression evidence. Logs, fixtures and exact SHAs: %s\n' "$output"
