#!/usr/bin/env bash
# Sets the series base aside when the Chromium checkout moves to another version, so step 4 captures a fresh one.
#
#   retire-series-base.sh SRC BASE VERSION
#
# SRC is the Chromium tree, BASE the series base (AC_SERIES_BASE) and VERSION the version about to be synced.
# The checkout's version comes from SRC/chrome/VERSION. A base for that same version stays. Otherwise BASE moves to
# BASE.<checkout version> (BASE.unknown without a checkout), with .<n> added when that name is taken.
set -euo pipefail
case "${1:-}" in
  -h | --help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
if [[ $# -ne 3 ]]; then
  echo "usage: retire-series-base.sh SRC BASE VERSION" >&2
  exit 64
fi
src=$1
base=$2
version=$3
[[ -d "$base" ]] || exit 0
synced=""
if [[ -f "$src/chrome/VERSION" ]]; then
  synced=$(awk -F= '{ part[$1] = $2 } END { if (part["MAJOR"] != "") print part["MAJOR"] "." part["MINOR"] "." part["BUILD"] "." part["PATCH"] }' "$src/chrome/VERSION")
fi
[[ "$synced" == "$version" ]] && exit 0
retired="$base.${synced:-unknown}"
n=1
while [[ -e "$retired" ]]; do
  retired="$base.${synced:-unknown}.$n"
  n=$((n + 1))
done
mv "$base" "$retired"
echo "retire-series-base.sh: the series base for ${synced:-an unknown checkout} is now $retired; step 4 captures one for $version"
