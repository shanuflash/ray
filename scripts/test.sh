#!/bin/bash
# Runs the unit tests, then the hidden-app checks against build/RayTests.app (build it first).
#   scripts/test.sh [check …]        the named checks (none: the whole suite)
#   scripts/test.sh --changed [base]  only the checks the working tree's changes against base (default HEAD) can
#                                     affect, from tests/affected.mjs; boot, quit and restore always run
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = "--changed" ]; then
  shift
  echo "checks affected by changes against ${1:-HEAD}:"
  selected=$(node "$root/tests/changed.mjs" "$@")
  case "$selected" in
    all) set -- ;;
    "") set -- boot ;;
    *) read -r -a picked <<<"$selected"; set -- "${picked[@]}" ;;
  esac
  echo "running: ${*:-the whole suite}"
fi
# Ray's accents come from the profile's colour (Host/ProfileColor.swift), never the system accent.
if grep -n 'controlAccentColor' "$root"/Host/*.swift | grep -v 'Host/ProfileColor.swift'; then
  echo "error: use ProfileColor.accent instead of NSColor.controlAccentColor" >&2
  exit 1
fi
mkdir -p "$root/build/tests"
cp "$root/tests/AddressInputTests.swift" "$root/build/tests/main.swift"
xcrun swiftc -target arm64-apple-macos14.0 -D RAY_TEST_HOOKS "$root/Host/AddressInput.swift" \
  "$root/Host/TestEnvironment.swift" "$root/Host/ProfileColor.swift" "$root/build/tests/main.swift" \
  -o "$root/build/tests/address-input"
"$root/build/tests/address-input"
mkdir -p "$root/build/tests/safe-storage"
cp "$root/tests/SafeStorageTests.swift" "$root/build/tests/safe-storage/main.swift"
xcrun swiftc -target arm64-apple-macos14.0 -D RAY_TEST_HOOKS "$root/Host/SafeStorage.swift" \
  "$root/build/tests/safe-storage/main.swift" -o "$root/build/tests/safe-storage-tests"
"$root/build/tests/safe-storage-tests"
# The importer (Importer/, adapted from Ardia's packages/import): its own XCTest suite, against Importer/fixtures only.
importer=$(swift test --package-path "$root/Importer" --scratch-path "$root/build/importer" 2>&1) || {
  echo "$importer" | grep -E "error:" | head -20; echo "importer tests failed" >&2; exit 1; }
echo "$importer" | grep -E "Executed [0-9]+ tests" | tail -1
node "$root/tests/checks.mjs" "$@"
