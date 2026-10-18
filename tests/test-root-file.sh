#!/bin/bash
set -euo pipefail

# install_root_file and write_root_file set the file's group in the same install that writes it,
# when given one, so a file such as NUT's, which its daemons read through the group, can't be left
# root:root by a write that succeeded and a chgrp that didn't. Without a group, install gets none.
# confirm_sudo_changes says how to apply what it lists when it couldn't ask.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
# install runs for real, minus -g, since the sandbox's user can't give a file root's groups
# shellcheck disable=SC2016 # expanded by the stub
stub sudo 'if [ "$1" == install ]; then
    shift
    args=()
    while [ $# -gt 0 ]; do
        case "$1" in -g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    exec install "${args[@]}"
fi
exec "$@"'

dest="$SANDBOX/etc/nut/upsd.users"
assert_exit 0 write_root_file "$dest" "secret" 0640 nut
assert_eq secret "$(cat "$dest")" "file write_root_file wrote"
assert_eq 640 "$(file_mode "$dest")" "mode write_root_file set"
assert_file_contains "$STUB_LOG" "sudo install -m 0640 -g nut "

: > "$STUB_LOG"
printf 'other\n' > "$SANDBOX/src"
assert_exit 0 install_root_file "$SANDBOX/src" "$dest" "" nut
assert_eq other "$(cat "$dest")" "file install_root_file wrote"
assert_eq 640 "$(file_mode "$dest")" "mode install_root_file kept"
assert_file_contains "$STUB_LOG" "sudo install -m 640 -g nut "

: > "$STUB_LOG"
assert_exit 0 write_root_file "$SANDBOX/etc/plain.conf" "plain"
assert_file_contains "$STUB_LOG" "sudo install -m 644 "
assert_file_not_contains "$STUB_LOG" " -g "

# confirm_sudo_changes says to run the step from a terminal only when there was none to ask in
assert_exit 1 confirm_sudo_changes "Write /etc/example"
assert_contains "$RUN_OUTPUT" "    - Write /etc/example"
assert_contains "$RUN_OUTPUT" "Left unchanged. Run this step from a terminal to apply them."
is_interactive() { true; }
# shellcheck disable=SC2329 # confirm_sudo_changes calls it
confirm() { false; }
assert_exit 1 confirm_sudo_changes "Write /etc/example"
assert_contains "$RUN_OUTPUT" "Left unchanged."
assert_not_contains "$RUN_OUTPUT" "from a terminal"
test_done
