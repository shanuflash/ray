#!/bin/bash
# Runs the unit tests, then the hidden-app checks against build/RayTests.app (build it first).
#   scripts/test.sh [check …]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/build/tests"
cp "$root/tests/AddressInputTests.swift" "$root/build/tests/main.swift"
xcrun swiftc -target arm64-apple-macos14.0 -D RAY_TEST_HOOKS "$root/Host/AddressInput.swift" \
  "$root/Host/TestEnvironment.swift" "$root/build/tests/main.swift" \
  -o "$root/build/tests/address-input"
"$root/build/tests/address-input"
node "$root/tests/checks.mjs" "$@"
