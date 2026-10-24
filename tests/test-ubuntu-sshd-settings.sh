#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329

# The ubuntu step's sshd settings on a set-up machine: a drop-in only root can read, and sshd's
# effective settings, which an earlier file or a Match block can override.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up

# A drop-in only root can read is checked once sudo's credentials are cached. Skipped as root,
# which reads any file. A test can't make a file only root reads, so sudo's cat of an unreadable
# file prints <file>.root.
stub_sudo_cacheable '[ "$1" != cat ] || [ -r "$2" ] || exec cat "$2.root"'
cp "$SSHD_DROP_IN" "$SSHD_DROP_IN.root"
chmod 000 "$SSHD_DROP_IN"
if [ ! -r "$SSHD_DROP_IN" ]; then
    cache_sudo no
    assert_read_only 0 main --status
    assert_contains "$RUN_OUTPUT" "unverified $SSHD_DROP_IN"
    cache_sudo yes
    assert_read_only 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         $SSHD_DROP_IN"
    echo "# changed" > "$SSHD_DROP_IN.root"
    assert_read_only 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    $SSHD_DROP_IN"
fi
chmod 644 "$SSHD_DROP_IN"
rm "$SSHD_DROP_IN.root"
stub_sudo_cacheable

# sshd keeps the first value it reads, so an earlier drop-in can override ours
cache_sudo yes
unset SSH_USER_AUTH
me="$(id -un)"
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
item="sshd's effective settings match $SSHD_DROP_IN"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         $item"
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
assert_file_contains "$STUB_LOG" "sudo -n $SSHD_BIN -T"
printf '%s\n' "passwordauthentication yes" "allowusers someone" > "$SANDBOX/sshd-T"
first="another file, or a Match block, sets them first, which sudo grep -ri <setting> /etc/ssh finds"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $item (AllowUsers is someone $me; $first)"
assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off (PasswordAuthentication is yes; $first)"
assert_eq 1 "$(grep -c "PasswordAuthentication is yes" <<< "$RUN_OUTPUT")" "items naming PasswordAuthentication"
# As root, the password item is skipped and the settings item covers password logins
stub id 'if [ "$*" == -u ]; then echo 0; else exec /usr/bin/id "$@"; fi'
cp "$SSHD_DROP_IN" "$SANDBOX/drop-in-as-you"
sshd_drop_in > "$SANDBOX/drop-in-as-root"
mv "$SANDBOX/drop-in-as-root" "$SSHD_DROP_IN"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "skipped    Password and keyboard-interactive SSH logins off: the step leaves them to root"
assert_contains "$RUN_OUTPUT" "missing    $item (PasswordAuthentication is yes; $first)"
rm "$STUB_DIR/id"
mv "$SANDBOX/drop-in-as-you" "$SSHD_DROP_IN"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sshd doesn't take these settings from $SSHD_DROP_IN, since another file, or a Match block, sets them first:
    AllowUsers is someone $me
    PasswordAuthentication is yes"
assert_file_contains "$STUB_LOG" "sudo $SSHD_BIN -T"
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd-T"
# A Match block can override the drop-in for some logins, which sshd -T doesn't show, so the
# settings are unverified and the file named
printf '%s\n' "Match User $me" "    PasswordAuthentication yes" > "$SANDBOX/etc/ssh/sshd_config.d/99-match.conf"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified $item ($SANDBOX/etc/ssh/sshd_config.d/99-match.conf has a Match block"
assert_contains "$RUN_OUTPUT" "unverified Password and keyboard-interactive SSH logins off ($SANDBOX/etc/ssh/sshd_config.d/99-match.conf has a Match block"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 0 main
assert_contains "$RUN_OUTPUT" "$SANDBOX/etc/ssh/sshd_config.d/99-match.conf has a Match block, so whether sshd takes $SSHD_DROP_IN for every login is unchecked."
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/etc/ssh/sshd_config.d/99-match.conf"
# Password logins went off at the reload even though another setting failed
echo "permitrootlogin yes" > "$SANDBOX/sshd-T"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "    PermitRootLogin is yes"
assert_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd-T"
# sshd -T failing after the reload: keep the drop-in
touch "$SANDBOX/sshd-T-fails"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sudo sshd -T failed, so whether sshd takes $SSHD_DROP_IN is unchecked"
assert_eq "$(DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in when sshd -T fails"
# Unchecked, so it doesn't claim they're off
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified $item (sudo sshd -T failed"
rm "$SANDBOX/sshd-T-fails"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 0 main
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         $item"
cache_sudo no
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified $item"
assert_file_not_contains "$STUB_LOG" "sshd -T"
test_done
