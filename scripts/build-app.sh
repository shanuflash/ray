#!/bin/bash
# Builds build/Lumen.app: Host/*.mm linked against the prebuilt engine, signed ad hoc for local use.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fw_name="Chromium Framework"
fw_src=$("$root/scripts/fetch-engine.sh")
app="$root/build/Lumen.app"
bundle_id=${LUMEN_BUNDLE_ID:-dev.shanus.lumen}
version=0.0.1

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp -cR "$fw_src" "$app/Contents/Frameworks/"
fw_version=$(ls "$app/Contents/Frameworks/$fw_name.framework/Versions" | grep -v Current)

xcrun clang++ -std=c++20 -O2 -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc \
  -I"$root/vendor/ardiacore" \
  "$root"/Host/*.mm \
  "$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version/$fw_name" \
  -Wl,-rpath,@executable_path/../Frameworks \
  -framework AppKit \
  -o "$app/Contents/MacOS/Lumen"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Lumen</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>Lumen</string>
  <key>CFBundleDisplayName</key><string>Lumen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>BrowserCrApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST

identity=${LUMEN_SIGN_IDENTITY:--}
sign() { codesign --force --timestamp=none --sign "$identity" "$@" 2>/dev/null; }
fwv="$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version"
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
