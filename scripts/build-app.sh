#!/bin/bash
# Builds build/Ray.app (the user's app) and build/RayTests.app (same code plus test hooks, its own bundle id),
# both linked against the prebuilt engine and signed ad hoc for local use.
#   scripts/build-app.sh [ray|tests]     (default: both)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fw_name="Chromium Framework"
fw_src=$("$root/scripts/fetch-engine.sh")
bundle_id=${RAY_BUNDLE_ID:-dev.shanus.ray}
version=0.0.1
identity=${RAY_SIGN_IDENTITY:--}
sign() { codesign --force --timestamp=none --sign "$identity" "$@" 2>/dev/null; }

# Ray's icon at the sizes the engine's logo slots use, rendered once per change of the icon.
logos="$root/build/logos"
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [ ! -f "$logos/ray-256.png" ] || [ -n "$(find "$root/Branding/Ray.icon" -newer "$logos/ray-256.png" -print -quit)" ]; then
  mkdir -p "$logos"
  for size in 16 22 24 32 44 64 128 256; do
    "$ictool" "$root/Branding/Ray.icon" --export-image --output-file "$logos/ray-$size.png" --platform macOS \
      --rendition Default --width "$size" --height "$size" --scale 1 >/dev/null
  done
fi

build() {
  local app="$1" id="$2" name="$3"
  shift 3
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
  cp -cR "$fw_src" "$app/Contents/Frameworks/"
  local fw_version
  fw_version=$(ls "$app/Contents/Frameworks/$fw_name.framework/Versions" | grep -v Current)
  # The engine's own pages call the browser "Ardia" and show its logo; they say "Ray" and show Ray's icon instead.
  local res="$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version/Resources"
  python3 -I "$root/tools/rebrand-pak.py" --logos "$logos" \
    "$res"/*.lproj/locale.pak "$res/chrome_100_percent.pak" "$res/chrome_200_percent.pak" "$res/resources.pak"

  xcrun swiftc -O -target arm64-apple-macos14.0 -swift-version 5 "$@" \
    -import-objc-header "$root/Host/Bridging.h" -Xcc -I"$root/vendor/ardiacore" \
    "$root"/Host/*.swift \
    -Xlinker "$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version/$fw_name" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$app/Contents/MacOS/Ray"
  cp "$root"/Resources/* "$app/Contents/Resources/"
  # The app icon: an Icon Composer document, so macOS 26+ gets its light, dark, tinted and clear looks (Assets.car)
  # and older systems the .icns.
  xcrun actool "$root/Branding/Ray.icon" --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon Ray --target-device mac \
    --output-partial-info-plist "$app/Contents/icon.plist" >/dev/null
  rm -f "$app/Contents/icon.plist"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Ray</string>
  <key>CFBundleIconFile</key><string>Ray</string>
  <key>CFBundleIconName</key><string>Ray</string>
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
  sign "$app/Contents/MacOS/Ray"
  sign "$app"
  codesign --verify --deep --strict "$app"
  echo "$app"
}

which=${1:-both}
if [ "$which" = both ] || [ "$which" = ray ]; then
  build "$root/build/Ray.app" "$bundle_id" "Ray"
fi
if [ "$which" = both ] || [ "$which" = tests ]; then
  build "$root/build/RayTests.app" "$bundle_id.tests" "Ray Tests" -D RAY_TEST_HOOKS
fi
