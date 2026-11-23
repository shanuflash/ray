#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${CHROMIUM_SRC:-$HOME/chromium-build/chromium_git/chromium/src}
owned=(ray/linux)
mode=${1:-}
linux_logos=(chrome/app/theme/chromium/linux/product_logo_{24,48,64,128,256}.png chrome/app/theme/default_100_percent/chromium/linux/product_logo_{16,32}.png)
case "$mode" in
  --paths) printf '%s\n' ray/core/ac_hooks.h ray/core/ac_content_hooks.h ray/core/ac_host_visibility.h ray/core/ac_launch_switches.h ray/core/ac_windowless_page.h ray/core/ac_test_media_route_provider.h ray/core/ac_test_media_route_provider.cc ray/core/page_script.js "${linux_logos[@]}"; exit 0 ;;
  ''|--check) ;;
  *) echo "usage: $0 [--check|--paths]" >&2; exit 64 ;;
esac
if [[ "$mode" != --check ]]; then
  for logo in "${linux_logos[@]}"; do
    [[ -f "$src/$logo" ]] || { echo "error: $logo isn't in the tree: the Linux logos replace Chromium's, they add none" >&2; exit 1; }
  done
fi
if [[ "$mode" == --check ]]; then
  diff -r "$here/src/ray/linux" "$src/ray/linux" >/dev/null || { echo "drift: ray/linux" >&2; exit 1; }
else
  mkdir -p "$src/ray/linux"
  rsync -rlp --delete --checksum "$here/src/ray/linux/" "$src/ray/linux/"
fi
copy_file() {
  local source=$1 target=$2
  if [[ "$mode" == --check ]]; then
    cmp -s "$source" "$target" || { echo "drift: ${target#"$src/"}" >&2; exit 1; }
  else
    mkdir -p "${target%/*}"
    cmp -s "$source" "$target" || cp "$source" "$target"
  fi
}
copy_file "$here/../raycore/src/ray/core/ac_hooks.h" "$src/ray/core/ac_hooks.h"
copy_file "$here/../raycore/src/ray/core/ac_content_hooks.h" "$src/ray/core/ac_content_hooks.h"
copy_file "$here/../raycore/src/ray/core/ac_host_visibility.h" "$src/ray/core/ac_host_visibility.h"
copy_file "$here/../raycore/src/ray/core/ac_launch_switches.h" "$src/ray/core/ac_launch_switches.h"
copy_file "$here/../raycore/src/ray/core/ac_windowless_page.h" "$src/ray/core/ac_windowless_page.h"
copy_file "$here/../raycore/src/ray/core/ac_test_media_route_provider.h" "$src/ray/core/ac_test_media_route_provider.h"
copy_file "$here/../raycore/src/ray/core/ac_test_media_route_provider.cc" "$src/ray/core/ac_test_media_route_provider.cc"
copy_file "$here/../../packages/raycore/ios/page_script.js" "$src/ray/core/page_script.js"
for logo in "${linux_logos[@]}"; do
  copy_file "$here/../chromium/src/${logo%/linux/*}/${logo##*/}" "$src/$logo"
done
for file in "$here"/src/ray/core/*; do
  copy_file "$file" "$src/ray/core/${file##*/}"
done
