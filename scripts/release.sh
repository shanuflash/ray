#!/bin/bash
# Prepares a Ray release for Sparkle: bumps VERSION, builds build/Ray.app, zips it, signs the zip with the EdDSA
# private key in your login keychain and writes the appcast, all under build/release/<version>/. It publishes nothing:
# it prints the `gh release create` command (and the commit to make first) for you to run.
#   scripts/release.sh <version> [--notes <file.md|.html|.txt>]
# Needs Branding/sparkle-public-key.txt to be the real key (Sparkle's generate_keys, once; see CLAUDE.md).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
repo=shanuflash/ray
die() { echo "error: $*" >&2; exit 1; }

version=${1:-}
notes=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) notes=${2:-}; [ -n "$notes" ] || die "--notes needs a file"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh <x.y.z> [--notes <file>]"
if [ -n "$notes" ]; then
  [ -f "$notes" ] || die "no such notes file: $notes"
  case "$notes" in *.md|*.html|*.txt) ;; *) die "release notes must be .md, .html or .txt" ;; esac
  notes=$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")
fi

# What's released is what's committed.
[ -z "$(git -C "$root" status --porcelain)" ] || die "the working tree has uncommitted changes; commit or stash them first"
branch=$(git -C "$root" rev-parse --abbrev-ref HEAD)

while IFS='=' read -r key value; do
  case "$key" in version|build) printf -v "current_$key" '%s' "$value" ;; esac
done < "$root/VERSION"
[ "$(printf '%s\n%s\n' "$current_version" "$version" | sort -V | tail -1)" = "$version" ] && [ "$version" != "$current_version" ] \
  || die "$version isn't newer than $current_version"
build=$((current_build + 1))

# The release key. RAY_RELEASE_ED_KEY_FILE exists only so the script itself can be tried with a throwaway key; the
# real key stays in the login keychain and is never read into a file, a variable or the log.
sparkle_dir=$("$root/scripts/fetch-sparkle.sh")
key_args=()
public=$(grep -v '^#' "$root/Branding/sparkle-public-key.txt" | tr -d '[:space:]')
[[ "$public" != REPLACE_* ]] || die "Branding/sparkle-public-key.txt is still the placeholder; run generate_keys first (CLAUDE.md, Shipping to friends)"
if [ -n "${RAY_RELEASE_ED_KEY_FILE:-}" ]; then
  key_args=(--ed-key-file "$RAY_RELEASE_ED_KEY_FILE")
else
  keychain_public=$("$sparkle_dir/bin/generate_keys" -p) || die "no Sparkle signing key in your keychain; run generate_keys first"
  [ "$keychain_public" = "$public" ] || die "the keychain's key isn't the one in Branding/sparkle-public-key.txt; builds with the wrong key can't be updated"
fi

# Put VERSION back if anything below fails.
original_version=$(cat "$root/VERSION")
finished=0
trap '[ "$finished" = 1 ] || printf "%s\n" "$original_version" > "$root/VERSION"' EXIT
printf 'version=%s\nbuild=%s\n' "$version" "$build" > "$root/VERSION"

"$root/scripts/build-app.sh" ray >/dev/null
app="$root/build/Ray.app"
plist_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
plist_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
plist_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app/Contents/Info.plist")
[ "$plist_version" = "$version" ] && [ "$plist_build" = "$build" ] || die "the built app says $plist_version ($plist_build)"
[ "$plist_key" = "$public" ] || die "the built app's SUPublicEDKey isn't Branding/sparkle-public-key.txt"

out="$root/build/release/$version"
rm -rf "$out"
mkdir -p "$out"
archive="Ray-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$archive"
# Sparkle checks the unpacked update's code signature too; make sure it survives the zip.
check=$(mktemp -d)
trap 'rm -rf "$check"; [ "$finished" = 1 ] || printf "%s\n" "$original_version" > "$root/VERSION"' EXIT
ditto -x -k "$out/$archive" "$check"
codesign --verify --deep --strict "$check/Ray.app" || die "the unzipped app's signature is broken"
# Friends' installs keep their Keychain and privacy permissions only while every release has the same identity.
codesign -dr - "$check/Ray.app" 2>&1 | grep -q 'certificate root = H"57dd31c307844623c2a646a24fb7f19c27327a4f"' \
  || die "the app isn't signed with \"Ray Code Signing\" (the self-signed certificate in your login keychain)"

if [ -n "$notes" ]; then
  notes_file="$out/Ray-$version.${notes##*.}"
  cp "$notes" "$notes_file"
else
  notes_file="$out/Ray-$version.txt"
  printf 'Ray %s\n' "$version" > "$notes_file"
fi

# generate_appcast reads the archive's Info.plist, signs it with the keychain key and writes the XML itself.
"$sparkle_dir/bin/generate_appcast" ${key_args[@]+"${key_args[@]}"} --embed-release-notes --disable-signing-warning \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --link "https://github.com/$repo" -o "$out/appcast.xml" "$out" >/dev/null

# The appcast must name this archive, this version and a signature, and nothing else.
python3 -I - "$out/appcast.xml" "$out/$archive" "$version" "$build" "https://github.com/$repo/releases/download/v$version/$archive" <<'PY'
import sys, os
import xml.etree.ElementTree as ET
appcast, archive, version, build, url = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(appcast).getroot().findall("./channel/item")
assert len(items) == 1, f"appcast has {len(items)} items"
item = items[0]
enclosure = item.find("enclosure")
sp = "{%s}" % ns["sparkle"]
assert enclosure.get("url") == url, f"enclosure url {enclosure.get('url')}"
assert enclosure.get(sp + "edSignature"), "enclosure has no EdDSA signature"
assert int(enclosure.get("length")) == os.path.getsize(archive), "enclosure length is wrong"
assert item.find("sparkle:version", ns).text == build, "sparkle:version is not the build number"
assert item.find("sparkle:shortVersionString", ns).text == version, "shortVersionString is wrong"
assert item.find("sparkle:minimumSystemVersion", ns) is not None, "no minimumSystemVersion"
PY

signature=$(python3 -I -c '
import sys, xml.etree.ElementTree as ET
e = ET.parse(sys.argv[1]).getroot().find("./channel/item/enclosure")
print(e.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"))' "$out/appcast.xml")
"$sparkle_dir/bin/sign_update" ${key_args[@]+"${key_args[@]}"} --verify "$out/$archive" "$signature" >/dev/null \
  || die "the archive's signature doesn't verify"

finished=1
echo
echo "Ray $version (build $build) is ready in $out:"
ls -lh "$out" | sed 's/^/  /'
echo
echo "Nothing is published. When you've tried it, run these in order:"
printf '  git add VERSION && git commit -m "chore: release %s" && git push\n' "$version"
printf '  gh release create v%s \\\n    "%s" \\\n    "%s" \\\n    --repo %s --target %s --title "Ray %s" \\\n    --notes-file "%s" --latest\n' \
  "$version" "$out/$archive" "$out/appcast.xml" "$repo" "$branch" "$version" "$notes_file"
