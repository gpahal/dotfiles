#!/bin/bash
set -euo pipefail

# install_root_file and write_root_file set the file's group in the same install that writes it,
# when given one, so a file such as NUT's, which its daemons read through the group, can't be left
# root:root by a write that succeeded and a chgrp that didn't. Without a group, install gets none.
# A destination that is a directory fails.
# confirm_sudo_changes says how to apply what it lists when it couldn't ask.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
# install runs for real, minus -g, since the sandbox's user can't give a file root's groups
stub_sudo_exec 'if [ "${1:-}" == install ]; then
    shift
    args=()
    while [ $# -gt 0 ]; do
        case "$1" in -g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    set -- install "${args[@]}"
fi'

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

# A destination that is a directory, or a link to one, fails, rather than install moving the new
# file into it
for kind in dir link; do
    dest="$SANDBOX/etc/sleep.conf.d/10-$kind.conf"
    if [ "$kind" == dir ]; then
        mkdir -p "$dest"
    else
        mkdir -p "$SANDBOX/etc/real-dir"
        ln -s "$SANDBOX/etc/real-dir" "$dest"
    fi
    assert_exit 1 write_root_file "$dest" "x"
    assert_contains "$RUN_OUTPUT" "$dest is a directory; remove it and re-run." "$kind destination"
    assert_eq "" "$(/bin/ls -A "$dest/")" "files in a $kind destination"
done

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
