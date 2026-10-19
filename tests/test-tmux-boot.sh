#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions
set -euo pipefail

# continuum enables tmux.service when a tmux server loads tmux.conf, so the step starts one

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REAL_TMUX="$(command -v tmux || true)"
setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"
load_script tmux/install.sh
as_os ubuntu
replace_fn sync_tmux_plugins

touch "$SANDBOX/manager"
stub systemctl 'case "$*" in
    "--user show-environment") [ -e "'"$SANDBOX"'/manager" ] ;;
    "--user is-enabled --quiet tmux.service") [ -e "'"$SANDBOX"'/enabled" ] ;;
    "--user enable tmux.service") touch "'"$SANDBOX"'/enabled" ;;
    *) exit 1 ;;
esac'
# start-server stands in for continuum enabling the unit
stub tmux 'echo "TMUX_TMPDIR=$TMUX_TMPDIR TMUX=${TMUX-unset}" >> "'"$SANDBOX"'/tmux-env"
[ "$1" != start-server ] || [ -e "'"$SANDBOX"'/broken" ] || touch "'"$SANDBOX"'/enabled"'

run status
assert_contains "$RUN_OUTPUT" "missing    tmux starts at boot (continuum's systemd user unit, tmux.service)"

# A server on a new socket, outside any tmux session
export TMUX=/tmp/outer,1,0
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Enabled tmux.service"
assert_file_contains "$STUB_LOG" "tmux start-server"
assert_file_contains "$STUB_LOG" "tmux kill-server"
assert_file_not_contains "$SANDBOX/tmux-env" "TMUX_TMPDIR=$TMUX_TMPDIR "
assert_file_contains "$SANDBOX/tmux-env" "TMUX=unset"
tmpdir="$(sed -n '1s/^TMUX_TMPDIR=\([^ ]*\) .*/\1/p' "$SANDBOX/tmux-env")"
[ -n "$tmpdir" ] && [ ! -e "$tmpdir" ] || fail "the server's socket dir is still there: '$tmpdir'"
unset TMUX
run status
assert_contains "$RUN_OUTPUT" "ok         tmux starts at boot (continuum's systemd user unit, tmux.service)"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "tmux already starts at boot"
assert_file_not_contains "$STUB_LOG" "tmux start-server"

rm "$SANDBOX/enabled"
touch "$SANDBOX/broken"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "continuum didn't enable tmux.service"

rm "$SANDBOX/manager"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Couldn't reach your systemd user manager"
assert_file_not_contains "$STUB_LOG" "tmux start-server"

# Real tmux and tmux.conf; the fake tpm enables the unit as continuum does
if [ -z "$REAL_TMUX" ]; then
    skip_rest "a real tmux server: tmux isn't installed"
    test_done
    exit 0
fi
rm -f "$STUB_DIR/tmux" "$SANDBOX/enabled" "$SANDBOX/broken"
touch "$SANDBOX/manager"
stub uname 'echo Linux'
mkdir -p "$HOME/.tmux/plugins/tpm"
printf '#!/bin/sh\nsleep 0.3\n[ "$(tmux show-option -gqv @continuum-boot)" != on ] || systemctl --user enable tmux.service\n' \
    > "$HOME/.tmux/plugins/tpm/tpm"
chmod +x "$HOME/.tmux/plugins/tpm/tpm"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Enabled tmux.service"
assert_file_contains "$STUB_LOG" "systemctl --user enable tmux.service"
test_done
