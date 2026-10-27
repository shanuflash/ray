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
mirror="${RAY_ENGINE_MIRROR:-$HOME/Library/Caches/Ray/engines}"
file="ArdiaCore-$short.tar.xz"
die() { echo "error: $*" >&2; exit 1; }

if [ ! -f "$dest/.complete" ]; then
  mkdir -p "$store" "$mirror"
  tmp="$store/.tmp-$$"
  rm -rf "$tmp" && mkdir -p "$tmp"
  trap 'rm -rf "$tmp"' EXIT
  if [ -f "$mirror/$file" ]; then
    cp "$mirror/$file" "$tmp/$file"
  else
    url="https://github.com/$repo/releases/download/$release/$file"
    echo "downloading $url" >&2
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/$file" "$url" || die "couldn't download $url"
  fi
  [ "$(shasum -a 256 "$tmp/$file" | awk '{print $1}')" = "$sha256" ] || die "$file doesn't match engine.lock's sha256"
  cp "$tmp/$file" "$mirror/$file.part" && mv "$mirror/$file.part" "$mirror/$file"
  tar -xJf "$tmp/$file" -C "$tmp" || die "couldn't unpack $file"
  rm -f "$tmp/$file"
  [ -f "$tmp/$name.framework/Versions/Current/$name" ] || die "$file holds no $name.framework"
  touch "$tmp/.complete"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  trap - EXIT
fi
echo "$dest/$name.framework"
