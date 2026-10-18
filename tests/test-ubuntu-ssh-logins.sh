#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# os: ubuntu

# The ubuntu step's SSH logins on a set-up machine (tests/ubuntu-step-fixture.sh): the drop-in's
# settings, turning password logins off only on a key login's evidence (or the VM opt-in), and never
# back on, and leaving them to root.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
ubuntu_step_set_up

# --- the sshd drop-in's settings ---
# Always: no root logins, a keepalive, only you, and sshd's record of each session's login in
# $SSH_USER_AUTH
unset DOTFILES_SSH_KEY_ONLY SSH_USER_AUTH
rm -f "$SSHD_DROP_IN"
me="$(id -un)"
drop_in="$(sshd_drop_in)"
assert_contains "$drop_in" "PermitRootLogin no"
assert_contains "$drop_in" "ClientAliveInterval 60"
assert_contains "$drop_in" "AllowUsers $me"
assert_contains "$drop_in" "ExposeAuthInfo yes"
# No key yet: password logins stay on
assert_not_contains "$drop_in" "PasswordAuthentication"
mkdir -p "$HOME/.ssh"
chmod 755 "$HOME"
chmod 700 "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/login-key"
ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/other-key"
# ssh-keygen also accepts authorized_keys options, as sshd does
printf 'restrict,command="echo hello" %s\n' "$(cat "$SANDBOX/login-key.pub")" > "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
# sshd writes a line per method the session logged in with, with the key for publickey, and
# removes the file when the session ends
SSH_AUTH_FILE="$SANDBOX/sshauth.XXXX"
key_session() {
    printf 'publickey %s\n' "$(cut -d' ' -f1,2 "$SANDBOX/$1.pub")" > "$SSH_AUTH_FILE"
    export SSH_USER_AUTH="$SSH_AUTH_FILE"
}
# key_only_pending <reason> <where> [status]: main keeps password logins on, saying why, and with
# status, so does status. MAIN_OUTPUT keeps main's output.
key_only_pending() {
    assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in $2"
    : > "$STUB_LOG"
    run main
    MAIN_OUTPUT="$RUN_OUTPUT"
    assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
    assert_contains "$RUN_OUTPUT" "Password logins stay on: $1"
    [ "${3:-}" == status ] || return 0
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off ($1"
    assert_contains "$RUN_OUTPUT" "ssh-copy-id <alias> from the Mac, with the alias just ssh-host added, or this machine's LAN IP before Tailscale is up"
}
# A console run: a key in authorized_keys, and DOTFILES_ASSUME_YES, don't prove it logs in
key_only_pending "this run isn't in an SSH session that sshd recorded the login of" "on the console" status
# An invalid line, or a truncated key, is no key either
for invalid in 'not-a-key ssh-just-a-note' 'ssh-ed25519 AAAAC3Nza me@mac'; do
    printf 'publickey %s\n' "$invalid" > "$SSH_AUTH_FILE"
    export SSH_USER_AUTH="$SSH_AUTH_FILE"
    assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in for an invalid key"
done
# A password session, or one that took a password after the key
printf 'password\n' > "$SSH_AUTH_FILE"
key_only_pending "this SSH session logged in with a password" "in a password session"
key_session login-key
printf 'keyboard-interactive/pam\n' >> "$SSH_AUTH_FILE"
key_only_pending "this SSH session logged in with a password" "in a session that also took a password" status
# ssh may have reused a connection that logged in with a password, so the step says how to close it
hint="If you logged in with your key, ssh reused an earlier connection: on the Mac, run ssh -O exit <alias>, then SSH in again."
assert_contains "$RUN_OUTPUT" "(this SSH session logged in with a password. $hint Copy your key over"
assert_contains "$MAIN_OUTPUT" "Password logins stay on: this SSH session logged in with a password. $hint"
# A tmux pane that outlived its SSH session: sshd removed the file
export SSH_USER_AUTH="$SANDBOX/sshauth.gone"
key_only_pending "the SSH session this shell started in has ended" "in a stale tmux pane"
# A key that authorized_keys doesn't list, or no longer does
key_session other-key
key_only_pending "the key this SSH session logged in with isn't in ~/.ssh/authorized_keys" "with another key"
# A key session: password logins go off, once you agree
key_session login-key
assert_contains "$(sshd_drop_in)" "PasswordAuthentication no"
DOTFILES_ASSUME_YES=0 run main
assert_contains "$RUN_OUTPUT" "Write $SSHD_DROP_IN, turning off SSH password logins since this SSH session logged in with your key SHA256:"
# One item for the drop-in, not one to write it and another to turn password logins off
assert_eq 1 "$(grep -c "$SSHD_DROP_IN" <<< "$RUN_OUTPUT")" "pending items naming the drop-in"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
run main
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
assert_file_contains "$SSHD_DROP_IN" "KbdInteractiveAuthentication no"
assert_contains "$RUN_OUTPUT" "Keep this session open, and on the Mac check a fresh login with: ssh -S none <alias> true"
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
# A second run changes nothing, even from the console, and asks nothing
unset SSH_USER_AUTH
: > "$STUB_LOG"
run main
assert_not_contains "$RUN_OUTPUT" "$SSHD_DROP_IN"
assert_file_not_contains "$STUB_LOG" "tee $SSHD_DROP_IN"
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
# Never turned back on: not with the key gone from authorized_keys
mv "$HOME/.ssh/authorized_keys" "$SANDBOX/authorized_keys"
assert_contains "$(sshd_drop_in)" "PasswordAuthentication no" "the drop-in once the key is gone"
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
# The opt-in for disposable VMs turns them off without a key login, or any key
rm "$SSHD_DROP_IN"
assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in without a key"
export DOTFILES_SSH_KEY_ONLY=1
run main
assert_contains "$RUN_OUTPUT" "Write $SSHD_DROP_IN, turning off SSH password logins since DOTFILES_SSH_KEY_ONLY=1 is set: "
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
unset DOTFILES_SSH_KEY_ONLY
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
mv "$SANDBOX/authorized_keys" "$HOME/.ssh/authorized_keys"

# Run as root: no AllowUsers root, which with PermitRootLogin no would refuse everyone. Password
# logins that are off stay off, but root's key doesn't turn them off.
id() { if [ "${1:-}" == -u ]; then echo 0; else echo root; fi; }
drop_in="$(sshd_drop_in)"
fresh_drop_in="$(sshd_drop_in "")"
unset -f id
assert_contains "$drop_in" "PermitRootLogin no"
assert_not_contains "$drop_in" "AllowUsers"
assert_contains "$drop_in" "PasswordAuthentication no"
assert_contains "$drop_in" "KbdInteractiveAuthentication no"
assert_not_contains "$fresh_drop_in" "PasswordAuthentication"
test_done
