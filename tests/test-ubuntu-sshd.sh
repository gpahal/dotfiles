#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329

# The ubuntu step's sshd drop-in on a set-up machine: rollback when sshd rejects it or its reload
# fails, a broken file beside it, and no sshd. test-ubuntu-sshd-settings.sh covers sshd's effective
# settings, and test-ubuntu-sshd-key-only.sh password logins.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up

# --- the sshd drop-in ---
echo "# old" > "$SSHD_DROP_IN"
assert_exit 0 main
assert_eq "$(sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the new drop-in"
assert_file_contains "$STUB_LOG" "sudo systemctl try-reload-or-restart ssh.service"

echo '# old, working' > "$SSHD_DROP_IN"
stub_systemctl '[ "$1" != try-reload-or-restart ] || exit 1'
assert_exit 1 main
assert_eq '# old, working' "$(cat "$SSHD_DROP_IN")" "sshd rollback after failed activation"
# The rollback failing too leaves the new drop-in, which the step says
wrap_fn write_root_file '[ "$2" != "# old, working" ] || return 1; real_write_root_file "$@"'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "the new $SSHD_DROP_IN
  is still in place"
restore_fn write_root_file
echo '# old, working' > "$SSHD_DROP_IN"
stub_systemctl
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl try-reload-or-restart ssh.service"

# A broken file elsewhere: the drop-in stays and the step does the rest
echo "# old, working" > "$SSHD_DROP_IN"
echo "Bogus yes" > "$SANDBOX/etc/ssh/sshd_config.d/50-other.conf"
rm "$SLEEP_CONF"
assert_exit 1 main
assert_eq "# old, working" "$(cat "$SSHD_DROP_IN")" "the drop-in beside a broken file"
assert_contains "$RUN_OUTPUT" "$SANDBOX/etc/ssh/sshd_config.d/50-other.conf"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"
[ -e "$SLEEP_CONF" ] || fail "the step stopped at the sshd failure"
rm "$SANDBOX/etc/ssh/sshd_config.d/50-other.conf"

replace_fn sshd_drop_in 'echo "Bogus new"'
assert_exit 1 main
assert_eq "# old, working" "$(cat "$SSHD_DROP_IN")" "the drop-in after sshd rejected the new one"
assert_contains "$RUN_OUTPUT" "$SSHD_DROP_IN"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"
wrap_fn write_root_file '[ "$2" != "# old, working" ] || return 1; real_write_root_file "$@"'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "the broken drop-in is still in place: $SSHD_DROP_IN"
assert_not_contains "$RUN_OUTPUT" "the old one is back"
restore_fn write_root_file
echo "# old, working" > "$SSHD_DROP_IN"

rm "$SSHD_DROP_IN"
assert_exit 1 main
[ ! -e "$SSHD_DROP_IN" ] || fail "a rejected drop-in was kept"

# No sshd, as when openssh-server failed to install
unset -f sshd_drop_in
SSHD_BIN="$SANDBOX/no-sshd"
assert_exit 1 configure_sshd
assert_contains "$RUN_OUTPUT" "sshd isn't installed"
assert_file_not_contains "$STUB_LOG" "sshd -t"
[ ! -e "$SSHD_DROP_IN" ] || fail "a drop-in was written without sshd"
# shellcheck disable=SC2034 # configure_sshd reads it
SSHD_BIN="$STUB_DIR/sshd"

# The override above removed the real sshd_drop_in
unset -f sshd_drop_in
ubuntu_step_load
stub systemctl 'case "$1" in is-enabled) echo enabled ;; mask) exit 1 ;; esac'
rm -f "$SANDBOX/ufw-on" "$SSHD_DROP_IN"
assert_exit 1 main
assert_file_contains "$STUB_LOG" "sudo systemctl mask"
assert_eq "$(sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in after a failed mask"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

stub_systemctl
assert_exit 0 main
test_done
