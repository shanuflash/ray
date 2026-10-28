step_name=$(basename "$0")
case "${1:-}" in
  -h | --help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
  --apply) ;;
  *) echo "$step_name: it changes ~/chromium-build: pass --apply to run it (--help for usage)" >&2; exit 64 ;;
esac
step_refuse() { echo "$step_name: $*" >&2; exit 64; }
step_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
step_cb_in="${AC_CHROMIUM_BUILD:-$HOME/chromium-build}"
step_why=$(python3 "$step_dir/pathguard.py" build-root "$step_cb_in") && step_class=0 || step_class=$?
case "$step_class" in
  0) step_lock=chromium ;;
  10) step_lock=real ;;
  *) step_refuse "the build root $step_cb_in doesn't stay in one place: ${step_why:-unreadable}" ;;
esac
step_cb=$(cd "$step_cb_in" 2>/dev/null && pwd -P) || step_refuse "no build root at $step_cb_in"
if [[ -n "${CHROMIUM_SRC:-}" ]]; then
  step_src=$(cd "$CHROMIUM_SRC" 2>/dev/null && pwd -P) || step_src="$CHROMIUM_SRC"
  step_want=$(cd "$step_cb/chromium_git/chromium/src" 2>/dev/null && pwd -P) || step_want="$step_cb/chromium_git/chromium/src"
  [[ "$step_src" == "$step_want" ]] || step_refuse "CHROMIUM_SRC=$CHROMIUM_SRC is not the tree of the build root $step_cb (set AC_CHROMIUM_BUILD to its build root)"
fi
if [[ $step_lock == real && "$(cd "${AC_LOCK_ROOT:-/tmp}" 2>/dev/null && pwd -P)" != "$(cd /tmp && pwd -P)" ]]; then
  step_refuse "$step_why: the real ~/chromium-build needs the real chromium lock: unset AC_LOCK_ROOT"
fi
python3 "$step_dir/pathguard.py" lock-held || step_refuse "hold the chromium lock: scripts/agent/locked chromium --as <you> -- $0 --apply"
export AC_CHROMIUM_BUILD="$step_cb"
unset step_dir step_cb_in step_why step_class step_lock step_cb step_src step_want
