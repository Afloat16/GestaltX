#!/usr/bin/env bash
set -euo pipefail

out="${RUNNER_TEMP:-/tmp}/gestaltx-tests"
mkdir -p "$out"
sources=(
  GestaltX/GestaltDocument.swift GestaltX/Capabilities.swift
  GestaltX/DeviceCacheOptions.swift GestaltX/MobileGestaltCacheLayout.swift
  GestaltX/Localization.swift GestaltX/AdvancedUnlockSequence.swift
  GestaltX/DevicePlistIdentity.swift GestaltX/DeviceBoundPlist.swift
  Shared/SharedPlistInbox.swift
)
for optional in ShareExtension/ItemProviderLoad.swift GestaltX/SharedImportQueue.swift; do
  if [[ -f "$optional" ]]; then sources+=("$optional"); fi
done
for test in tests/*Tests.swift; do
  name="$(basename "$test" .swift)"
  echo "Running $name"
  swiftc -swift-version 5 -parse-as-library "${sources[@]}" "$test" -o "$out/$name"
  python3 - "$out/$name" <<'PY'
import subprocess, sys
try:
    subprocess.run([sys.argv[1]], check=True, timeout=90)
except subprocess.TimeoutExpired:
    raise SystemExit(f"Timed out after 90 seconds: {sys.argv[1]}")
PY
done
python3 scripts/generate_localization.py
node scripts/verify_respring.mjs
