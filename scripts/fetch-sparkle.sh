#!/bin/bash
# Downloads the Sparkle release pinned in sparkle.lock, checks its SHA-256, unpacks it under build/sparkle and prints
# the unpacked folder (it holds Sparkle.framework and bin/ with generate_keys, sign_update, generate_appcast).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
while IFS='=' read -r key value; do
  case "$key" in version|url|sha256) printf -v "$key" '%s' "$value" ;; esac
done < "$root/sparkle.lock"
dest="$root/build/sparkle/$version"
mirror="${RAY_SPARKLE_MIRROR:-$HOME/Library/Caches/Ray/sparkle}"
file="Sparkle-$version.tar.xz"
die() { echo "error: $*" >&2; exit 1; }

if [ ! -f "$dest/.complete" ]; then
  mkdir -p "$root/build/sparkle" "$mirror"
  tmp="$root/build/sparkle/.tmp-$$"
  rm -rf "$tmp" && mkdir -p "$tmp"
  trap 'rm -rf "$tmp"' EXIT
  if [ -f "$mirror/$file" ]; then
    cp "$mirror/$file" "$tmp/$file"
  else
    echo "downloading $url" >&2
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/$file" "$url" || die "couldn't download $url"
  fi
  [ "$(shasum -a 256 "$tmp/$file" | awk '{print $1}')" = "$sha256" ] || die "$file doesn't match sparkle.lock's sha256"
  cp "$tmp/$file" "$mirror/$file.part" && mv "$mirror/$file.part" "$mirror/$file"
  mkdir "$tmp/unpacked"
  tar -xJf "$tmp/$file" -C "$tmp/unpacked" || die "couldn't unpack $file"
  [ -f "$tmp/unpacked/Sparkle.framework/Versions/B/Sparkle" ] || die "$file holds no Sparkle.framework"
  for tool in generate_keys sign_update generate_appcast; do
    [ -x "$tmp/unpacked/bin/$tool" ] || die "$file holds no bin/$tool"
  done
  touch "$tmp/unpacked/.complete"
  rm -rf "$dest"
  mv "$tmp/unpacked" "$dest"
fi
echo "$dest"
