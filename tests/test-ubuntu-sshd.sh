#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The ubuntu step's sshd drop-in on a set-up machine: rollback when sshd rejects it, sshd's effective
# settings, and password logins going off only on proof of a key login, never back on.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
ubuntu_step_set_up

# --- the sshd drop-in ---
echo "# old" > "$SSHD_DROP_IN"
: > "$STUB_LOG"
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
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl try-reload-or-restart ssh.service"

# A broken file elsewhere: the drop-in stays and the step does the rest
echo "# old, working" > "$SSHD_DROP_IN"
echo "Bogus yes" > "$SANDBOX/sshd_config.d/50-other.conf"
rm "$SLEEP_CONF"
: > "$STUB_LOG"
assert_exit 1 main
assert_eq "# old, working" "$(cat "$SSHD_DROP_IN")" "the drop-in beside a broken file"
assert_contains "$RUN_OUTPUT" "$SANDBOX/sshd_config.d/50-other.conf"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"
[ -e "$SLEEP_CONF" ] || fail "the step stopped at the sshd failure"
rm "$SANDBOX/sshd_config.d/50-other.conf"

replace_fn sshd_drop_in 'echo "Bogus new"'
: > "$STUB_LOG"
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
: > "$STUB_LOG"
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
: > "$STUB_LOG"
assert_exit 1 main
assert_file_contains "$STUB_LOG" "sudo systemctl mask"
assert_eq "$(sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in after a failed mask"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

stub_systemctl
assert_exit 0 main

# --- sshd's effective settings ---
# sshd keeps the first value it reads, so an earlier drop-in can override ours
cache_sudo yes
unset SSH_USER_AUTH
me="$(id -un)"
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
item="sshd's effective settings match $SSHD_DROP_IN"
: > "$STUB_LOG"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         $item"
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
assert_file_contains "$STUB_LOG" "sudo -n $SSHD_BIN -T"
printf '%s\n' "PasswordAuthentication yes" "AllowUsers someone" > "$SANDBOX/sshd_config.d/00-local.conf"
# A later file loses to the drop-in, so it isn't named
echo "PermitRootLogin yes" > "$SANDBOX/sshd_config.d/50-cloud-init.conf"
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
: > "$STUB_LOG"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sshd doesn't take these settings from $SSHD_DROP_IN, since another file, or a Match block, sets them first:
    AllowUsers is someone $me
    PasswordAuthentication is yes"
assert_file_contains "$STUB_LOG" "sudo $SSHD_BIN -T"
assert_eq "PasswordAuthentication yes
AllowUsers someone" "$(cat "$SANDBOX/sshd_config.d/00-local.conf")" "the other drop-in"
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/00-local.conf" "$SANDBOX/sshd_config.d/50-cloud-init.conf"
# sshd -T applies a Match block for a login by you from this machine
printf '%s\n' "Match User $me" "    PasswordAuthentication yes" > "$SANDBOX/sshd_config.d/99-match.conf"
: > "$STUB_LOG"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "ok         $item"
assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off (PasswordAuthentication is yes;"
assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=127.0.0.1,addr=127.0.0.1"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "    PasswordAuthentication is yes"
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/99-match.conf"
# Match Address: private, tailnet, and named addresses are each sampled, and a negated one never
# is. status_sshd alone, after one full status run.
assert_exit 0 main --status
ubuntu_items
for match in "192.168.1.1 192.168.1.1" "100.64.0.1 100.64.0.1" "203.0.113.7 203.0.113.7" \
    "!10.9.9.9,192.168.7.1 192.168.7.1"; do
    addr="${match##* }"
    printf '%s\n' "Match Address ${match% *}" "    PasswordAuthentication yes" > "$SANDBOX/sshd_config.d/99-match.conf"
    : > "$STUB_LOG"
    run status_sshd
    assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off (PasswordAuthentication is yes for $addr;"
    assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=$addr,addr=$addr"
done
assert_file_not_contains "$STUB_LOG" "addr=10.9.9.9"
rm "$SANDBOX/sshd_config.d/99-match.conf"
for match in "10.* 10.1" "* 1" "192.168.1.? 192.168.1.1" "fd00::/8 fd00::1" "fd00::* fd00::1" \
    "fd00:*:1 fd00:1::1:1" "2001:db8:0:0:0:0:0:* 2001:db8:0:0:0:0:0:1" "fe80::1 fe80::1"; do
    assert_eq "${match##* }" "$(range_sample "${match% *}")" "range_sample ${match% *}"
done
export SSH_CONNECTION="198.51.100.4 51000 192.168.1.5 22"
: > "$STUB_LOG"
assert_exit 0 main --status
unset SSH_CONNECTION
assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=198.51.100.4,addr=198.51.100.4"
# Password logins went off at the reload even though another setting failed
echo "PermitRootLogin yes" > "$SANDBOX/sshd_config.d/00-local.conf"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "    PermitRootLogin is yes"
assert_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/00-local.conf"
# sshd -T failing after the reload: keep the drop-in, and leave ufw alone without the SSH ports
touch "$SANDBOX/sshd-T-fails"
rm "$SSHD_DROP_IN" "$SANDBOX/ufw-on"
: > "$STUB_LOG"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sudo sshd -T -C user=$me,host=127.0.0.1,addr=127.0.0.1 failed"
assert_eq "$(DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in when sshd -T fails"
# Unchecked, so it doesn't claim they're off
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
assert_contains "$RUN_OUTPUT" "Couldn't read the SSH ports with sudo sshd -T"
assert_file_not_contains "$STUB_LOG" "ufw default"
assert_file_not_contains "$STUB_LOG" "ufw allow"
assert_file_not_contains "$STUB_LOG" "ufw --force enable"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "unverified $item (sudo sshd -T -C user=$me,host=127.0.0.1,addr=127.0.0.1 failed"
rm "$SANDBOX/sshd-T-fails"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 0 main
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         $item"
cache_sudo no
: > "$STUB_LOG"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified $item"
assert_file_not_contains "$STUB_LOG" "sshd -T"

# --- password logins: off only on proof of a key login, never back on ---
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
    : > "$STUB_LOG"
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
