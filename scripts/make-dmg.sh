#!/bin/bash
# Ray's DMG for first installs: Ray.app, an Applications link, a background that says how to open an un-notarized app
# the first time, Ray's icon on the volume, signed with the app's own certificate. Built-in tools only (hdiutil,
# tools/dmg-window.swift for the window). The image is mounted hidden (-nobrowse) at a private mount point; Ray is
# never run from it. release.sh calls it; it can also be tried on its own:
#   scripts/make-dmg.sh <Ray.app> <out.dmg>
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "error: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: scripts/make-dmg.sh <Ray.app> <out.dmg>"
app=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$2
[ -d "$app" ] || die "no app at $1"
volname=Ray

# The same certificate as the app (its leaf, by SHA-1), so the image's Team ID is the app's.
work=$(mktemp -d)
mounted=""
cleanup() {
  [ -z "$mounted" ] || hdiutil detach "$mounted" -force -quiet || true
  rm -rf "$work"
}
trap cleanup EXIT
codesign -d --extract-certificates="$work/cert" "$app" 2>/dev/null
[ -s "$work/cert0" ] || die "the app isn't signed with a certificate (ad-hoc); build with your Apple Development identity"
identity=$(shasum -a 1 "$work/cert0" | awk '{ print toupper($1) }')
team=$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')

# The window's background, at 1x and 2x in one TIFF (what Finder wants for Retina).
swiftc -O -o "$work/dmg-window" "$root/tools/dmg-window.swift" 2>"$work/swiftc.log" || { cat "$work/swiftc.log" >&2; die "tools/dmg-window.swift didn't build"; }
"$work/dmg-window" background "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff" >/dev/null 2>&1

# A read-write HFS+ image with room for the app, laid out, then compressed (LZFSE; macOS 14+ reads it).
size_mb=$(( $(du -sm "$app" | cut -f1) + 40 ))
hdiutil create -quiet -size "${size_mb}m" -fs HFS+ -volname "$volname" -type UDIF -layout GPTSPUD "$work/rw.dmg"
mkdir "$work/mnt"
hdiutil attach -quiet -nobrowse -noautoopen -noverify -readwrite -mountpoint "$work/mnt" "$work/rw.dmg"
mounted="$work/mnt"
ditto "$app" "$mounted/Ray.app"
ln -s /Applications "$mounted/Applications"
mkdir "$mounted/.background"
cp "$work/background.tiff" "$mounted/.background/background.tiff"
cp "$app/Contents/Resources/Ray.icns" "$mounted/.VolumeIcon.icns"
"$work/dmg-window" layout "$mounted" "$volname" "Ray.app"
chflags hidden "$mounted/.background" "$mounted/.VolumeIcon.icns" "$mounted/.DS_Store"
# kHasCustomIcon on the volume, for .VolumeIcon.icns.
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$mounted"
rm -rf "$mounted/.fseventsd" "$mounted/.Trashes"
hdiutil detach -quiet "$mounted"
mounted=""
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format ULFO -o "$out"
codesign --force --timestamp=none --sign "$identity" "$out" 2>/dev/null || die "couldn't sign the DMG"

# What friends get: a signed image with the app's Team ID, a valid app inside, the window's files in place.
codesign --verify --strict "$out" || die "the DMG's signature doesn't verify"
dmg_team=$(codesign -dvv "$out" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ -n "$team" ] && [ "$dmg_team" = "$team" ] || die "the DMG's Team ID ($dmg_team) isn't the app's ($team)"
hdiutil verify -quiet "$out" || die "the DMG doesn't verify"
mkdir "$work/check"
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$work/check" "$out"
mounted="$work/check"
codesign --verify --deep --strict "$mounted/Ray.app" || die "Ray.app in the DMG doesn't verify"
app_team=$(codesign -dvv "$mounted/Ray.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$app_team" = "$team" ] || die "Ray.app in the DMG has Team ID $app_team, not $team"
[ "$(readlink "$mounted/Applications")" = /Applications ] || die "the DMG has no Applications link"
for f in .DS_Store .background/background.tiff .VolumeIcon.icns; do
  [ -s "$mounted/$f" ] || die "the DMG has no $f"
done
hdiutil detach -quiet "$mounted"
mounted=""
