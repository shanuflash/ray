#!/bin/bash
# Prints the path of the engine framework Ray builds against, as engine.lock says:
#   source=local     Ray's own engine (Phase B), built from engine/ in ~/chromium-build (RAY_ENGINE_FRAMEWORK
#                    overrides the path). It must have been built already: engine/patches/build/05-build.sh.
#   source=prebuilt  a published Ray engine (none yet): downloads RayCore-<tree>.tar.xz from repo's release, checks
#                    it against sha256 and unpacks it into build/engine. (Ardia's own prebuilt engine, Phase A,
#                    can't link any more: its classes are ArdiaCore*, and it reads Ardia's keychain item.)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source=prebuilt
while IFS='=' read -r key value; do
  case "$key" in source|tree|release|sha256|repo) printf -v "$key" '%s' "$value" ;; esac
done < "$root/engine.lock"
name="Chromium Framework"
die() { echo "error: $*" >&2; exit 1; }

if [ "$source" = local ]; then
  framework="${RAY_ENGINE_FRAMEWORK:-$HOME/chromium-build/chromium_git/chromium/src/out/Release_GN_arm64/$name.framework}"
  [ -f "$framework/Versions/Current/$name" ] || die "no engine at $framework: build it (engine/patches/build, steps 1, 3, 4, 2, 5)"
  echo "$framework"
  exit 0
fi

[ -n "${tree:-}" ] && [ -n "${release:-}" ] && [ -n "${sha256:-}" ] && [ -n "${repo:-}" ] ||
  die "engine.lock: source=$source needs tree, release, sha256 and repo"
short=${tree:0:12}
store="$root/build/engine"
dest="$store/$short"
mirror="${RAY_ENGINE_MIRROR:-$HOME/Library/Caches/Ray/engines}"
file="RayCore-$short.tar.xz"

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
