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
mkdir -p "$root/build/tests"
cp "$root/tests/AddressInputTests.swift" "$root/build/tests/main.swift"
xcrun swiftc -target arm64-apple-macos14.0 -D RAY_TEST_HOOKS "$root/Host/AddressInput.swift" \
  "$root/Host/TestEnvironment.swift" "$root/build/tests/main.swift" \
  -o "$root/build/tests/address-input"
"$root/build/tests/address-input"
node "$root/tests/checks.mjs" "$@"
