#!/bin/bash
# Quits the user's running Ray (a normal macOS quit, whichever copy is running), installs build/Ray.app as
# /Applications/Ray.app (the owner's one copy, the one in the Dock) and opens it in front, on the default data dir.
# The owner asked for this (2026-10-29): two copies sharing one profile made the Dock icon hand off and quit.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bundle_id=${RAY_BUNDLE_ID:-dev.shanus.ray}
built="$root/build/Ray.app"
installed=${RAY_INSTALL_PATH:-/Applications/Ray.app}
[ -x "$built/Contents/MacOS/Ray" ] || { echo "error: no $built; run scripts/build-app.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$built" || { echo "error: $built's signature is broken" >&2; exit 1; }

# Any Ray with this bundle id: the installed copy, or an older build/Ray.app still running from the repo. Matched on
# the executable, not the command line: another session's swiftc ends its arguments with `-o …/Ray.app/Contents/MacOS/Ray`.
running() { ps -axo comm= | grep -qE "/Ray.app/Contents/MacOS/Ray$"; }
if running; then
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    running || break
    sleep 0.25
  done
  if running; then
    echo "error: Ray didn't quit within 10 s; quit it and run this again" >&2
    exit 1
  fi
fi

# Copy next to the installed app, then swap, so a failed copy never leaves a half-written Ray in /Applications.
staging="$installed.installing"
rm -rf "$staging"
ditto "$built" "$staging"
rm -rf "$installed"
mv "$staging" "$installed"
open "$installed"
echo "installed $built as $installed and opened it"
