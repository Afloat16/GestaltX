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
for test in tests/*Tests.swift; do
  name="$(basename "$test" .swift)"
  echo "Running $name"
  swiftc -swift-version 5 -parse-as-library "${sources[@]}" "$test" -o "$out/$name"
  "$out/$name"
done
python3 scripts/generate_localization.py
node scripts/verify_respring.mjs
