#!/bin/bash
# Builds build/Lumen.app (the user's app) and build/LumenTests.app (same code plus test hooks, its own bundle id),
# both linked against the prebuilt engine and signed ad hoc for local use.
#   scripts/build-app.sh [lumen|tests]     (default: both)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fw_name="Chromium Framework"
fw_src=$("$root/scripts/fetch-engine.sh")
bundle_id=${LUMEN_BUNDLE_ID:-dev.shanus.lumen}
version=0.0.1
identity=${LUMEN_SIGN_IDENTITY:--}
sign() { codesign --force --timestamp=none --sign "$identity" "$@" 2>/dev/null; }

build() {
  local app="$1" id="$2" name="$3"
  shift 3
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
  cp -cR "$fw_src" "$app/Contents/Frameworks/"
  local fw_version
  fw_version=$(ls "$app/Contents/Frameworks/$fw_name.framework/Versions" | grep -v Current)

  xcrun swiftc -O -target arm64-apple-macos14.0 -swift-version 5 "$@" \
    -import-objc-header "$root/Host/Bridging.h" -Xcc -I"$root/vendor/ardiacore" \
    "$root"/Host/*.swift \
    -Xlinker "$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version/$fw_name" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$app/Contents/MacOS/Lumen"
  cp "$root"/Resources/* "$app/Contents/Resources/"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Lumen</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>BrowserCrApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST

  local fwv="$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version"
  for lib in "$fwv"/Libraries/*.dylib; do sign "$lib"; done
  for helper in "$fwv"/Helpers/*.app "$fwv"/Helpers/chrome_crashpad_handler "$fwv"/Helpers/app_mode_loader \
    "$fwv"/Helpers/web_app_shortcut_copier; do
    [ -e "$helper" ] && sign "$helper"
  done
  sign "$app/Contents/Frameworks/$fw_name.framework"
  sign "$app/Contents/MacOS/Lumen"
  sign "$app"
  codesign --verify --deep --strict "$app"
  echo "$app"
}

which=${1:-both}
if [ "$which" = both ] || [ "$which" = lumen ]; then
  build "$root/build/Lumen.app" "$bundle_id" "Lumen"
fi
if [ "$which" = both ] || [ "$which" = tests ]; then
  build "$root/build/LumenTests.app" "$bundle_id.tests" "Lumen Tests" -D LUMEN_TEST_HOOKS
fi
