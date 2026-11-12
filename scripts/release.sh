#!/bin/bash
# Prepares a Ray release for Sparkle: bumps VERSION, builds build/Ray.app, zips it, signs the zip with the EdDSA
# private key in your login keychain and writes the appcast, then the DMG for first installs, all under
# build/release/<version>/, with the Homebrew cask (ray.rb) pointing at that DMG. It publishes nothing: it prints the
# `gh release create` command, the commit to make first and the tap's commit to make after.
# Delta updates: the last few published releases' zips (downloaded once from GitHub, checked to be signed by this
# app's team, cached in ~/Library/Caches/Ray/releases) go next to the new zip, so generate_appcast writes a
# small .delta from each to this version; each is applied and checked before the release is ready.
#   scripts/release.sh <version> [--notes <file.md|.html|.txt>] [--deltas <n, default 3; 0 for none>]
# Needs Branding/sparkle-public-key.txt to be the real key (Sparkle's generate_keys, once; see CLAUDE.md).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
repo=shanuflash/ray
die() { echo "error: $*" >&2; exit 1; }

version=${1:-}
notes=""
deltas=3
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) notes=${2:-}; [ -n "$notes" ] || die "--notes needs a file"; shift 2 ;;
    --deltas) deltas=${2:-}; [[ "$deltas" =~ ^[0-9]+$ ]] || die "--deltas needs a number"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh <x.y.z> [--notes <file>] [--deltas <n>]"
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
# Friends' installs keep "Ray Safe Storage" without a prompt per update only with a Team ID (the keychain's partition
# list), and their privacy permissions only while every release has the same identity.
codesign -dvv "$check/Ray.app" 2>&1 | grep -E '^TeamIdentifier=[A-Z0-9]{10}$' >/dev/null \
  || die "the app has no Team ID: build with your Apple Development certificate (Xcode › Settings › Apple Accounts)"

if [ -n "$notes" ]; then
  notes_file="$out/Ray-$version.${notes##*.}"
  cp "$notes" "$notes_file"
else
  notes_file="$out/Ray-$version.txt"
  printf 'Ray %s\n' "$version" > "$notes_file"
fi

# MARK: Deltas
# Most releases leave the engine alone, so a delta is a few hundred KB against a 146 MB zip. Deltas come from the
# zips friends actually have: the published ones, never a local rebuild. An install a delta can't patch (no delta
# from its version, or a bundle changed since) gets the full zip from Sparkle.
old_zips=()
cache="$HOME/Library/Caches/Ray/releases"
if [ "$deltas" -gt 0 ]; then
  command -v gh >/dev/null || die "deltas need gh (or pass --deltas 0)"
  mkdir -p "$cache"
  tags=$(gh release list --repo "$repo" --limit 30 --exclude-drafts --exclude-pre-releases --json tagName -q '.[].tagName') \
    || die "gh can't list $repo's releases (gh auth status), or pass --deltas 0"
  for tag in $tags; do
    old=${tag#v}
    [[ "$old" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$old" != "$version" ] || continue
    [ "$(printf '%s\n%s\n' "$old" "$version" | sort -V | tail -1)" = "$version" ] || continue
    zip="Ray-$old.zip"
    if [ ! -f "$cache/$zip" ]; then
      part="$cache/$old.part"
      rm -rf "$part"
      mkdir -p "$part"
      gh release download "$tag" --repo "$repo" -p "$zip" -D "$part" >/dev/null \
        || { rm -rf "$part"; echo "note: $tag has no $zip; no delta from it" >&2; continue; }
      # Only a Ray signed by the same team as this one (friends' installs check the same).
      ditto -x -k "$part/$zip" "$part/app"
      codesign --verify --deep --strict "$part/app/Ray.app" \
        && [ "$(codesign -dvv "$part/app/Ray.app" 2>&1 | grep '^TeamIdentifier=')" = "$(codesign -dvv "$check/Ray.app" 2>&1 | grep '^TeamIdentifier=')" ] \
        || { rm -rf "$part"; die "$tag's $zip isn't a Ray signed by this app's team"; }
      mv "$part/$zip" "$cache/$zip"
      rm -rf "$part"
    fi
    cp -c "$cache/$zip" "$out/$zip" 2>/dev/null || cp "$cache/$zip" "$out/$zip"
    old_zips+=("$zip")
    [ "${#old_zips[@]}" -lt "$deltas" ] || break
  done
fi

# generate_appcast reads the archives' Info.plists, signs the new zip and each delta with the keychain key and writes
# the XML itself: one version in the feed, the older zips only as delta sources.
"$sparkle_dir/bin/generate_appcast" ${key_args[@]+"${key_args[@]}"} --embed-release-notes --disable-signing-warning \
  --maximum-versions 1 --maximum-deltas "$deltas" \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --link "https://github.com/$repo" -o "$out/appcast.xml" "$out" >/dev/null
for zip in ${old_zips[@]+"${old_zips[@]}"}; do rm -f "$out/$zip"; done
rm -rf "$out/old_updates"

# The appcast must name this archive, this version and a signature, and nothing else.
python3 -I - "$out/appcast.xml" "$out/$archive" "$version" "$build" "https://github.com/$repo/releases/download/v$version/$archive" "${#old_zips[@]}" > "$check.deltas" <<'PY'
import sys, os
import xml.etree.ElementTree as ET
appcast, archive, version, build, url, delta_count = sys.argv[1:]
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
deltas = item.findall("sparkle:deltas/enclosure", ns)
assert len(deltas) == int(delta_count), f"{len(deltas)} deltas for {delta_count} older releases"
prefix = url.rsplit("/", 1)[0] + "/"
seen = set()
for d in deltas:
    name = d.get("url")[len(prefix):]
    assert d.get("url").startswith(prefix) and "/" not in name and name.endswith(".delta"), f"delta url {d.get('url')}"
    path = os.path.join(os.path.dirname(archive), name)
    assert os.path.isfile(path) and int(d.get("length")) == os.path.getsize(path), f"delta {name} is missing or the wrong length"
    assert d.get(sp + "edSignature"), f"delta {name} has no EdDSA signature"
    assert d.get(sp + "deltaFrom") not in seen, f"two deltas from {d.get(sp + 'deltaFrom')}"
    seen.add(d.get(sp + "deltaFrom"))
    print(name, d.get(sp + "deltaFrom"), d.get(sp + "edSignature"))
PY

signature=$(python3 -I -c '
import sys, xml.etree.ElementTree as ET
e = ET.parse(sys.argv[1]).getroot().find("./channel/item/enclosure")
print(e.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"))' "$out/appcast.xml")
"$sparkle_dir/bin/sign_update" ${key_args[@]+"${key_args[@]}"} --verify "$out/$archive" "$signature" >/dev/null \
  || die "the archive's signature doesn't verify"

# Each delta must verify, and patch the release it's from into exactly this app (same code directory hash, valid
# signature), as Sparkle will on friends' Macs.
new_cdhash=$(codesign -dvvv "$check/Ray.app" 2>&1 | grep '^CDHash=')
delta_files=()
while read -r delta from delta_signature; do
  [ -n "$delta" ] || continue
  "$sparkle_dir/bin/sign_update" ${key_args[@]+"${key_args[@]}"} --verify "$out/$delta" "$delta_signature" >/dev/null \
    || die "$delta's signature doesn't verify"
  source_app=""
  for zip in ${old_zips[@]+"${old_zips[@]}"}; do
    dir="$check/from-${zip%.zip}"
    [ -d "$dir" ] || ditto -x -k "$cache/$zip" "$dir"
    if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$dir/Ray.app/Contents/Info.plist")" = "$from" ]; then
      source_app="$dir/Ray.app"
    fi
  done
  [ -n "$source_app" ] || die "$delta is from build $from, which isn't one of ${old_zips[*]}"
  "$sparkle_dir/bin/BinaryDelta" apply "$source_app" "$check/patched-$from.app" "$out/$delta" >/dev/null \
    || die "$delta doesn't apply to build $from"
  codesign --verify --deep --strict "$check/patched-$from.app" || die "$delta makes an app whose signature is broken"
  [ "$(codesign -dvvv "$check/patched-$from.app" 2>&1 | grep '^CDHash=')" = "$new_cdhash" ] \
    || die "$delta doesn't make this release's app"
  delta_files+=("$out/$delta")
done < "$check.deltas"
rm -f "$check.deltas"

# MARK: DMG and cask
# First installs: a DMG whose window says how to open an un-notarized Ray (scripts/make-dmg.sh checks it), and the
# cask (scripts/ray-cask.rb with this version and the DMG's sha256) for the owner's tap, shanuflash/homebrew-tap
# (`brew install shanuflash/tap/ray`; homebrew/cask takes no app that fails Gatekeeper). Made after generate_appcast,
# which would list a DMG in the folder as a second item. Updates stay on the zip.
dmg="Ray-$version.dmg"
"$root/scripts/make-dmg.sh" "$app" "$out/$dmg"
dmg_sha=$(shasum -a 256 "$out/$dmg" | cut -d' ' -f1)
sed -E -e "s/^  version \"[^\"]*\"$/  version \"$version\"/" -e "s/^  sha256 .*$/  sha256 \"$dmg_sha\"/" \
  "$root/scripts/ray-cask.rb" > "$out/ray.rb"
grep -qx "  version \"$version\"" "$out/ray.rb" && grep -qx "  sha256 \"$dmg_sha\"" "$out/ray.rb" \
  || die "scripts/ray-cask.rb has no version or sha256 line to update"

finished=1
echo
echo "Ray $version (build $build) is ready in $out:"
ls -lh "$out" | sed 's/^/  /'
echo
echo "Nothing is published. When you've tried it, run these in order:"
printf '  git add VERSION && git commit -m "chore: release %s" && git push\n' "$version"
printf '  gh release create v%s \\\n    "%s" \\\n    "%s" \\\n    "%s" \\\n' "$version" "$out/$archive" "$out/appcast.xml" "$out/$dmg"
for delta in ${delta_files[@]+"${delta_files[@]}"}; do printf '    "%s" \\\n' "$delta"; done
printf '    --repo %s --target %s --title "Ray %s" \\\n    --notes-file "%s" --latest\n' "$repo" "$branch" "$version" "$notes_file"
echo "Then, once the release is up, the tap (the first time: gh repo clone shanuflash/homebrew-tap ~/homebrew-tap):"
printf '  mkdir -p ~/homebrew-tap/Casks && cp "%s" ~/homebrew-tap/Casks/ray.rb\n' "$out/ray.rb"
printf '  git -C ~/homebrew-tap add Casks/ray.rb && git -C ~/homebrew-tap commit -m "ray %s" && git -C ~/homebrew-tap push\n' "$version"
