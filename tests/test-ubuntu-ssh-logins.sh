#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The ubuntu step's sshd drop-in: password logins go off only on proof of a key login, never back on.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
ubuntu_step_set_up

unset DOTFILES_SSH_KEY_ONLY SSH_USER_AUTH
rm -f "$SSHD_DROP_IN"
me="$(id -un)"
drop_in="$(sshd_drop_in)"
assert_contains "$drop_in" "PermitRootLogin no"
assert_contains "$drop_in" "ClientAliveInterval 60"
assert_contains "$drop_in" "AllowUsers $me"
assert_contains "$drop_in" "ExposeAuthInfo yes"
assert_not_contains "$drop_in" "PasswordAuthentication"
mkdir -p "$HOME/.ssh"
chmod 755 "$HOME"
chmod 700 "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/login-key"
ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/other-key"
# authorized_keys options must not hide the key
printf 'restrict,command="echo hello" %s\n' "$(cat "$SANDBOX/login-key.pub")" > "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
# sshd's ExposeAuthInfo file: one line per method, removed when the session ends
SSH_AUTH_FILE="$SANDBOX/sshauth.XXXX"
key_session() {
    printf 'publickey %s\n' "$(cut -d' ' -f1,2 "$SANDBOX/$1.pub")" > "$SSH_AUTH_FILE"
    export SSH_USER_AUTH="$SSH_AUTH_FILE"
}
key_only_pending() {
    assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in $2"
    : > "$STUB_LOG"
    run main
    MAIN_OUTPUT="$RUN_OUTPUT"
    assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
    assert_contains "$RUN_OUTPUT" "Password logins stay on: $1"
    assert_contains "$RUN_OUTPUT" "Copy your key over (ssh-copy-id <alias> from the Mac, with the alias just ssh-host added, or this machine's LAN IP before Tailscale is up), SSH in with it, and re-run the ubuntu step."
    [ "${3:-}" == status ] || return 0
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off ($1"
    assert_contains "$RUN_OUTPUT" "ssh-copy-id <alias> from the Mac, with the alias just ssh-host added, or this machine's LAN IP before Tailscale is up"
}
# A console run proves nothing
key_only_pending "this run isn't in an SSH session that sshd recorded the login of" "on the console" status
for invalid in 'not-a-key ssh-just-a-note' 'ssh-ed25519 AAAAC3Nza me@mac'; do
    printf 'publickey %s\n' "$invalid" > "$SSH_AUTH_FILE"
    export SSH_USER_AUTH="$SSH_AUTH_FILE"
    assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in for an invalid key"
done
printf 'password\n' > "$SSH_AUTH_FILE"
key_only_pending "this SSH session logged in with a password" "in a password session"
key_session login-key
printf 'keyboard-interactive/pam\n' >> "$SSH_AUTH_FILE"
key_only_pending "this SSH session logged in with a password" "in a session that also took a password" status
# ssh may have reused a connection that logged in with a password
hint="If you logged in with your key, ssh reused an earlier connection: on the Mac, run ssh -O exit <alias>, then SSH in again."
assert_contains "$RUN_OUTPUT" "(this SSH session logged in with a password. $hint Copy your key over"
assert_contains "$MAIN_OUTPUT" "Password logins stay on: this SSH session logged in with a password. $hint"
# A tmux pane that outlived its SSH session
export SSH_USER_AUTH="$SANDBOX/sshauth.gone"
key_only_pending "the SSH session this shell started in has ended" "in a stale tmux pane"
key_session other-key
key_only_pending "the key this SSH session logged in with isn't in ~/.ssh/authorized_keys" "with another key"
# AuthenticationMethods publickey,publickey: both keys must be listed
for keys in "other-key login-key" "login-key other-key"; do
    : > "$SSH_AUTH_FILE"
    for key in $keys; do
        printf 'publickey %s\n' "$(cut -d' ' -f1,2 "$SANDBOX/$key.pub")" >> "$SSH_AUTH_FILE"
    done
    export SSH_USER_AUTH="$SSH_AUTH_FILE"
    key_only_pending "the key this SSH session logged in with isn't in ~/.ssh/authorized_keys" "with keys $keys"
done
key_session login-key
assert_contains "$(sshd_drop_in)" "PasswordAuthentication no"
DOTFILES_ASSUME_YES=0 run main
assert_contains "$RUN_OUTPUT" "Write $SSHD_DROP_IN, turning off SSH password logins since this SSH session logged in with your key SHA256:"
assert_eq 1 "$(grep -c "$SSHD_DROP_IN" <<< "$RUN_OUTPUT")" "pending items naming the drop-in"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
run main
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
assert_file_contains "$SSHD_DROP_IN" "KbdInteractiveAuthentication no"
assert_contains "$RUN_OUTPUT" "Keep this session open, and on the Mac check a fresh login with: ssh -S none <alias> true"
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
unset SSH_USER_AUTH
: > "$STUB_LOG"
run main
assert_not_contains "$RUN_OUTPUT" "$SSHD_DROP_IN"
assert_file_not_contains "$STUB_LOG" "tee $SSHD_DROP_IN"
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
# Never turned back on
mv "$HOME/.ssh/authorized_keys" "$SANDBOX/authorized_keys"
assert_contains "$(sshd_drop_in)" "PasswordAuthentication no" "the drop-in once the key is gone"
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
# The disposable-VM opt-in needs no key
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

# As root: AllowUsers root with PermitRootLogin no would refuse everyone
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
