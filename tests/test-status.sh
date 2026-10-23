#!/bin/bash

# The ubuntu step's full status, with sudo's credentials cached or not, never prompts or changes
# anything, and checks a file only root can read once they're cached.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up
unset DOTFILES_ASSUME_YES

# sudo records anything but a read in $SANDBOX/mutations. A test can't make a file only root reads,
# so `cat <file>` of an unreadable file prints <file>.root.
stub_sudo_cacheable 'case "$1 ${2:-}" in
    "true "* | "cat "* | "test "* | "sh -c" | *"/sshd -T" | "ufw status") ;;
    *) echo "$*" >> "$SANDBOX/mutations"; exit 1 ;;
esac
[ "$1" != cat ] || [ -r "$2" ] || exec cat "$2.root"'
no_prompting_sudo() {
    assert_sudo_noninteractive
    if [ -s "$SANDBOX/mutations" ]; then
        fail "status ran sudo to change something:"
        _show "$(cat "$SANDBOX/mutations")"
    fi
    : > "$STUB_LOG"
    : > "$SANDBOX/mutations"
}

: > "$STUB_LOG"
cache_sudo no
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified ufw rules"
no_prompting_sudo

cache_sudo yes
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         ufw rules"
assert_not_contains "$RUN_OUTPUT" "unverified"
no_prompting_sudo

# Skipped as root, which reads any file
cp "$SSHD_DROP_IN" "$SSHD_DROP_IN.root"
chmod 000 "$SSHD_DROP_IN"
if [ ! -r "$SSHD_DROP_IN" ]; then
    cache_sudo no
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "unverified $SSHD_DROP_IN"
    no_prompting_sudo
    cache_sudo yes
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         $SSHD_DROP_IN"
    no_prompting_sudo
    echo "# changed" > "$SSHD_DROP_IN.root"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    $SSHD_DROP_IN"
    no_prompting_sudo
fi
chmod 644 "$SSHD_DROP_IN"
test_done
