#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329

# The ubuntu step's SSH password logins on a set-up machine: off only on proof of a key login,
# never back on.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up

unset DOTFILES_SSH_KEY_ONLY SSH_USER_AUTH
rm -f "$SSHD_DROP_IN"
assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication"
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
    run main
    MAIN_OUTPUT="$RUN_OUTPUT"
    assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
    assert_contains "$RUN_OUTPUT" "Password logins stay on: $1"
    [ "${3:-}" == status ] || return 0
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off ($1"
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
assert_contains "$RUN_OUTPUT" "ssh -O exit <alias>"
assert_contains "$MAIN_OUTPUT" "ssh -O exit <alias>"
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
assert_contains "$RUN_OUTPUT" "turning off SSH password logins since this SSH session logged in with your key SHA256:"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
run main
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
assert_file_contains "$SSHD_DROP_IN" "KbdInteractiveAuthentication no"
assert_contains "$RUN_OUTPUT" "Keep this session open"
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
unset SSH_USER_AUTH
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
assert_contains "$RUN_OUTPUT" "turning off SSH password logins since DOTFILES_SSH_KEY_ONLY=1 is set"
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
