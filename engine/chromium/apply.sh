#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${CHROMIUM_SRC:-$HOME/chromium-build/chromium_git/chromium/src}
owned=(chrome/browser/ray)

replaced() {
  local prune=() dir
  for dir in "${owned[@]}"; do prune+=(-path "./$dir" -prune -o); done
  (cd "$here/src" && find . "${prune[@]}" -type f ! -name '.*' -print | sed 's|^\./||' | sort)
}
if [[ "${1:-}" == --paths ]]; then
  replaced
  exit 0
fi

for dir in "${owned[@]}"; do
  if [[ "${1:-}" == --check ]]; then
    diff -r "$here/src/$dir" "$src/$dir" >/dev/null || { echo "drift: $dir" >&2; exit 1; }
  else
    mkdir -p "$src/$dir"
    rsync -rlp --delete --checksum "$here/src/$dir/" "$src/$dir/"
  fi
done

while IFS= read -r path; do
  [[ -f "$src/$path" ]] || { echo "error: $path isn't in the tree: src/ replaces Chromium's files, it adds none" >&2; exit 1; }
  if [[ "${1:-}" == --check ]]; then
    cmp -s "$here/src/$path" "$src/$path" || { echo "drift: $path" >&2; exit 1; }
  else
    cmp -s "$here/src/$path" "$src/$path" || cp "$here/src/$path" "$src/$path"
  fi
done < <(replaced)
