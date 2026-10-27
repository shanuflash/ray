#!/bin/bash
# Quits the user's running Lumen (a normal macOS quit) and opens build/Lumen.app in front, on the default data dir.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bundle_id=${LUMEN_BUNDLE_ID:-dev.shanus.lumen}
binary="$root/build/Lumen.app/Contents/MacOS/Lumen"
if pgrep -f "$binary" >/dev/null; then
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    pgrep -f "$binary" >/dev/null || break
    sleep 0.25
  done
  if pgrep -f "$binary" >/dev/null; then
    echo "error: Lumen didn't quit within 10 s; quit it and run this again" >&2
    exit 1
  fi
fi
open "$root/build/Lumen.app"
echo "opened $root/build/Lumen.app"
