#!/bin/bash
# Quits the user's running Ray (a normal macOS quit) and opens build/Ray.app in front, on the default data dir.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bundle_id=${RAY_BUNDLE_ID:-dev.shanus.ray}
binary="$root/build/Ray.app/Contents/MacOS/Ray"
if pgrep -f "$binary" >/dev/null; then
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    pgrep -f "$binary" >/dev/null || break
    sleep 0.25
  done
  if pgrep -f "$binary" >/dev/null; then
    echo "error: Ray didn't quit within 10 s; quit it and run this again" >&2
    exit 1
  fi
fi
open "$root/build/Ray.app"
echo "opened $root/build/Ray.app"
