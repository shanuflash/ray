#!/bin/bash
# Downloads Ardia's prebuilt engine pinned in engine.lock, checks its SHA-256, and prints the framework path.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
while IFS='=' read -r key value; do
  case "$key" in tree|release|sha256|repo) printf -v "$key" '%s' "$value" ;; esac
done < "$root/engine.lock"
name="Chromium Framework"
short=${tree:0:12}
store="$root/build/engine"
dest="$store/$short"
mirror="${LUMEN_ENGINE_MIRROR:-$HOME/Library/Caches/Lumen/engines}"
file="ArdiaCore-$short.tar.xz"
die() { echo "error: $*" >&2; exit 1; }

if [ ! -f "$dest/.complete" ]; then
  mkdir -p "$store" "$mirror"
  tmp="$store/.tmp-$$"
  rm -rf "$tmp" && mkdir -p "$tmp"
  trap 'rm -rf "$tmp"' EXIT
  if [ ! -f "$mirror/$file" ] || [ "$(shasum -a 256 "$mirror/$file" | awk '{print $1}')" != "$sha256" ]; then
    url="https://github.com/$repo/releases/download/$release/$file"
    echo "downloading $url" >&2
    curl -fsSL --retry 3 -o "$mirror/$file.part" "$url" || die "couldn't download $url"
    mv "$mirror/$file.part" "$mirror/$file"
  fi
  [ "$(shasum -a 256 "$mirror/$file" | awk '{print $1}')" = "$sha256" ] || die "$file doesn't match engine.lock's sha256"
  tar -xJf "$mirror/$file" -C "$tmp" || die "couldn't unpack $file"
  [ -f "$tmp/$name.framework/Versions/Current/$name" ] || die "$file holds no $name.framework"
  touch "$tmp/.complete"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  trap - EXIT
fi
echo "$dest/$name.framework"
