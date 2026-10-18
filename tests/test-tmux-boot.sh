#!/bin/bash
# The step's functions call the OS checks this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On Ubuntu, the tmux step has tmux-continuum enable its systemd user unit, tmux.service, which
# starts tmux at boot. continuum does that when a tmux server loads tmux.conf, so the step starts
# one on a new socket, and fails when the unit still isn't enabled. Without a user manager to
# reach, as in a container, it says so and carries on. Stubs stand in for tmux, systemctl, and the
# plugin install, which test-tmux-plugins.sh covers, then a real tmux server loads the real
# tmux.conf, with a fake tpm in place of continuum.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REAL_TMUX="$(command -v tmux || true)"
setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"
load_script tmux/install.sh
is_ubuntu() { true; }
is_macos() { false; }
sync_tmux_plugins() { :; }

# The unit is enabled once the enabled file exists. No user manager without the manager file.
touch "$SANDBOX/manager"
stub systemctl 'case "$*" in
    "--user show-environment") [ -e "'"$SANDBOX"'/manager" ] ;;
    "--user is-enabled --quiet tmux.service") [ -e "'"$SANDBOX"'/enabled" ] ;;
    "--user enable tmux.service") touch "'"$SANDBOX"'/enabled" ;;
    *) exit 1 ;;
esac'
# start-server stands in for continuum enabling the unit, unless the broken file exists
stub tmux 'echo "TMUX_TMPDIR=$TMUX_TMPDIR TMUX=${TMUX-unset}" >> "'"$SANDBOX"'/tmux-env"
[ "$1" != start-server ] || [ -e "'"$SANDBOX"'/broken" ] || touch "'"$SANDBOX"'/enabled"'

run status
assert_contains "$RUN_OUTPUT" "missing    tmux starts at boot (continuum's systemd user unit, tmux.service)"

# A tmux server on a new socket, outside any tmux session, loads the config. The unit is enabled,
# and the server is gone.
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

# Already enabled, no server starts
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "tmux already starts at boot"
assert_file_not_contains "$STUB_LOG" "tmux start-server"

# continuum not enabling the unit fails the step
rm "$SANDBOX/enabled"
touch "$SANDBOX/broken"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "continuum didn't enable tmux.service"

# Without a user manager, no server starts and the step carries on
rm "$SANDBOX/manager"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Couldn't reach your systemd user manager"
assert_file_not_contains "$STUB_LOG" "tmux start-server"

# A real tmux server loads the real tmux.conf, which turns @continuum-boot on outside macOS, and
# start-server returns once tpm has run continuum. The fake tpm enables the unit as continuum does.
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
