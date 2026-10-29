#!/bin/bash
# Builds build/Ray.app (the user's app) and build/RayTests.app (same code plus test hooks, its own bundle id),
# both linked against the prebuilt engine and signed ad hoc for local use.
#   scripts/build-app.sh [ray|tests]     (default: both)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fw_name="Chromium Framework"
fw_src=$("$root/scripts/fetch-engine.sh")
bundle_id=${RAY_BUNDLE_ID:-dev.shanus.ray}
# Version and build number live in VERSION (scripts/release.sh bumps them); Sparkle compares the build number.
while IFS='=' read -r key value; do
  case "$key" in version|build) printf -v "$key" '%s' "$value" ;; esac
done < "$root/VERSION"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ && "$build" =~ ^[0-9]+$ ]] || { echo "error: VERSION is malformed" >&2; exit 1; }
# Sparkle 2: embedded in both apps (the test app never starts it), updates come from the release feed and are
# accepted only with an EdDSA signature that matches this public key (Branding/sparkle-public-key.txt; the private
# half lives in the maintainer's login keychain, see CLAUDE.md "Shipping to friends").
sparkle_dir=$("$root/scripts/fetch-sparkle.sh")
feed_url="https://github.com/shanuflash/ray/releases/latest/download/appcast.xml"
sparkle_key=$(grep -v '^#' "$root/Branding/sparkle-public-key.txt" | tr -d '[:space:]')
[[ "$sparkle_key" =~ ^[A-Za-z0-9+/=_]+$ ]] || { echo "error: Branding/sparkle-public-key.txt is malformed" >&2; exit 1; }
if [[ "$sparkle_key" == REPLACE_* ]]; then
  echo "warning: Branding/sparkle-public-key.txt is still the placeholder; this build can't update itself" >&2
  echo "         (run Sparkle's generate_keys once, see CLAUDE.md \"Shipping to friends\")" >&2
fi
# MARK: Signing
# One identity with a Team ID for every build. macOS keeps privacy permissions per designated requirement, but the
# "Ray Safe Storage" keychain item's partition list names an app by its Team ID, or else by each build's cdhash (a
# password prompt per build). The owner's Apple Development certificate (free Personal Team, renewed yearly in Xcode)
# has one; "Ray Code Signing" (self-signed, no Team ID) keeps only permissions; without either, ad-hoc. CLAUDE.md,
# Shipping to friends. No `grep -q`/`exit` in these pipes: under pipefail an early exit kills `security` (SIGPIPE).
if [ -z "${RAY_SIGN_IDENTITY:-}" ]; then
  RAY_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development: / && !found { print $2; found = 1 }')
fi
if [ -z "${RAY_SIGN_IDENTITY:-}" ] && security find-identity -p codesigning 2>/dev/null | grep '"Ray Code Signing"' >/dev/null; then
  RAY_SIGN_IDENTITY="Ray Code Signing"
fi
identity=${RAY_SIGN_IDENTITY:--}
sign() { codesign --force --timestamp=none --sign "$identity" "$@" 2>/dev/null; }
# MARK: Build

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
  # Ray's own engine is copied out of ~/chromium-build under the chromium lock, so a build running there can't hand
  # us a half-written framework.
  if [[ "$fw_src" == "$HOME/chromium-build/"* ]]; then
    "$root/scripts/locked" chromium --wait 500 -- cp -cR "$fw_src" "$app/Contents/Frameworks/"
  else
    cp -cR "$fw_src" "$app/Contents/Frameworks/"
  fi
  cp -cR "$sparkle_dir/Sparkle.framework" "$app/Contents/Frameworks/"
  # The XPC services are for sandboxed apps only (sparkle-project.org/documentation/sandboxing); Ray isn't sandboxed.
  rm -rf "$app/Contents/Frameworks/Sparkle.framework/XPCServices" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
  local fw_version
  fw_version=$(ls "$app/Contents/Frameworks/$fw_name.framework/Versions" | grep -v Current)
  # The engine's own pages call the browser "Ardia" and show its logo; they say "Ray" and show Ray's icon instead.
  local res="$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version/Resources"
  python3 -I "$root/tools/rebrand-pak.py" --logos "$logos" \
    "$res"/*.lproj/locale.pak "$res/chrome_100_percent.pak" "$res/chrome_200_percent.pak" "$res/resources.pak"
  # Ray has its own Settings window for Appearance and Profiles: they leave the engine's settings page. Exits 1 (and
  # stops the build, set -e) if the engine's page moved the code this edits.
  python3 -I "$root/tools/trim-settings-pak.py" "$res/resources.pak"

  xcrun swiftc -O -target arm64-apple-macos14.0 -swift-version 5 "$@" -F "$sparkle_dir" -framework Sparkle \
    -import-objc-header "$root/Host/Bridging.h" -Xcc -I"$root/engine/raycore/src/ray/core/public" \
    "$root"/Host/*.swift "$root"/Importer/Sources/RayImport/*.swift \
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
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>BrowserCrApplication</string>
  <key>SUFeedURL</key><string>$feed_url</string>
  <key>SUPublicEDKey</key><string>$sparkle_key</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <!-- Settings › General › Install updates automatically starts on: Sparkle downloads quietly, installs on quit. -->
  <key>SUAutomaticallyUpdate</key><true/>
  <!-- A web browser to macOS (System Settings › Desktop & Dock › Default web browser lists apps that take http,
       https and HTML): links come to AppController's application(_:open:) (Host/LinksFromApps.swift). No file:
       scheme, unlike Chrome: a file: link from another app is refused, files only come in as documents. The document
       types are Arc's and match AddressInput.documentTypes: HTML and XHTML, and PDF as an alternate (Open With),
       so Preview stays the default for PDFs. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key><array><string>public.html</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>XHTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key><array><string>public.xhtml</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>PDF document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <!-- What macOS shows when a site you allowed first asks for these; without them it kills the app (as Chrome declares). -->
  <key>NSCameraUsageDescription</key><string>Websites you allow can use your camera.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use your microphone.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Websites you allow can capture your Mac's audio when you share your screen.</string>
  <key>NSLocationUsageDescription</key><string>Websites you allow can use your location.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Websites you allow can use your location.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Websites you allow can connect to Bluetooth devices.</string>
</dict></plist>
PLIST

  local fwv="$app/Contents/Frameworks/$fw_name.framework/Versions/$fw_version"
  for lib in "$fwv"/Libraries/*.dylib; do sign "$lib"; done
  for helper in "$fwv"/Helpers/*.app "$fwv"/Helpers/chrome_crashpad_handler "$fwv"/Helpers/app_mode_loader \
    "$fwv"/Helpers/web_app_shortcut_copier; do
    [ -e "$helper" ] && sign "$helper"
  done
  sign "$app/Contents/Frameworks/$fw_name.framework"
  # Sparkle's helpers first, then the framework around them, then the app (inside out).
  local sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$sparkle/Autoupdate"
  sign "$sparkle/Updater.app"
  sign "$app/Contents/Frameworks/Sparkle.framework"
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
