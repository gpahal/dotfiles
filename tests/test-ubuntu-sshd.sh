#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The ubuntu step's sshd drop-in on a set-up machine (tests/ubuntu-step-fixture.sh): replacing it
# without removing a working one, rolling it back when sshd rejects it or won't reload, not blaming
# the config for a missing sshd, carrying on when one part fails, and checking sshd takes its
# settings, which another file can override, with sudo -n in status.

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
# A changed drop-in sshd accepts replaces the old one, and sshd reloads
echo "# old" > "$SSHD_DROP_IN"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "$(sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the new drop-in"
assert_file_contains "$STUB_LOG" "sudo systemctl try-reload-or-restart ssh.service"

# Failed activation restores the previous file, so a rerun retries it.
echo '# old, working' > "$SSHD_DROP_IN"
stub_systemctl '[ "$1" != try-reload-or-restart ] || exit 1'
assert_exit 1 main
assert_eq '# old, working' "$(cat "$SSHD_DROP_IN")" "sshd rollback after failed activation"
stub_systemctl
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl try-reload-or-restart ssh.service"

# A failed write leaves the old drop-in whole, its settings and all, and sshd isn't reloaded
printf '%s\n' "PermitRootLogin no" "PasswordAuthentication no" "# old" > "$SSHD_DROP_IN"
cp "$SSHD_DROP_IN" "$SANDBOX/drop-in-before"
stub mv 'case "$*" in *10-dotfiles.conf*) exit 1 ;; esac
exec /bin/mv "$@"'
: > "$STUB_LOG"
assert_exit 1 configure_sshd
rm "$STUB_DIR/mv"
assert_exit 0 cmp -s "$SSHD_DROP_IN" "$SANDBOX/drop-in-before"
assert_eq 10-dotfiles.conf "$(/bin/ls -A "$SANDBOX/sshd_config.d")" "files beside the drop-in after a failed write"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"

# A broken file elsewhere: the working drop-in stays, sshd isn't reloaded, the step names the
# file, and still does the rest
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

# A new drop-in sshd rejects: the old one goes back
sshd_drop_in() { echo "Bogus new"; }
: > "$STUB_LOG"
assert_exit 1 main
assert_eq "# old, working" "$(cat "$SSHD_DROP_IN")" "the drop-in after sshd rejected the new one"
assert_contains "$RUN_OUTPUT" "$SSHD_DROP_IN"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"
# When the old one can't go back, the step says the broken one is still in place
eval "real_write_root_file() $(declare -f write_root_file | tail -n +2)"
write_root_file() { [ "$2" != "# old, working" ] || return 1; real_write_root_file "$@"; }
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "the broken drop-in is still in place: $SSHD_DROP_IN"
assert_not_contains "$RUN_OUTPUT" "the old one is back"
eval "write_root_file() $(declare -f real_write_root_file | tail -n +2)"
echo "# old, working" > "$SSHD_DROP_IN"

# The same with no drop-in before: the rejected one is removed
rm "$SSHD_DROP_IN"
assert_exit 1 main
[ ! -e "$SSHD_DROP_IN" ] || fail "a rejected drop-in was kept"

# No sshd, as when installing openssh-server failed: the step says so, rather than blaming the
# config, and runs no sshd -t
unset -f sshd_drop_in
SSHD_BIN="$SANDBOX/no-sshd"
: > "$STUB_LOG"
assert_exit 1 configure_sshd
assert_contains "$RUN_OUTPUT" "sshd isn't installed"
assert_not_contains "$RUN_OUTPUT" "already fails sshd -t"
assert_file_not_contains "$STUB_LOG" "sshd -t"
[ ! -e "$SSHD_DROP_IN" ] || fail "a drop-in was written without sshd"
# shellcheck disable=SC2034 # configure_sshd reads it
SSHD_BIN="$STUB_DIR/sshd"

# A failed systemctl mask still sets up the rest, then fails
# The override above took the real sshd_drop_in with it, so load the step again
unset -f sshd_drop_in
ubuntu_step_load
stub systemctl 'case "$1" in is-enabled) echo enabled ;; mask) exit 1 ;; esac'
rm -f "$SANDBOX/ufw-on" "$SSHD_DROP_IN"
: > "$STUB_LOG"
assert_exit 1 main
assert_file_contains "$STUB_LOG" "sudo systemctl mask"
assert_eq "$(sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in after a failed mask"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# The rest starts from a machine set up again
stub_systemctl
assert_exit 0 main

# --- sshd's effective settings ---
# sshd keeps the first value it reads, so an earlier drop-in can turn a setting back on. Once the
# step writes the drop-in, it reads sshd -T and fails, naming each setting sshd doesn't take, and
# leaves the other file alone. Status reads sshd -T too, with sudo -n.
# sudo -n works here, as with cached credentials
stub_sudo_exec
unset SSH_USER_AUTH
me="$(id -un)"
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
item="sshd's effective settings match $SSHD_DROP_IN"
: > "$STUB_LOG"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $item"
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
assert_file_contains "$STUB_LOG" "sudo -n sshd -T"
printf '%s\n' "PasswordAuthentication yes" "AllowUsers someone" > "$SANDBOX/sshd_config.d/00-local.conf"
# A later file loses to the drop-in, so it isn't named
echo "PermitRootLogin yes" > "$SANDBOX/sshd_config.d/50-cloud-init.conf"
problems="AllowUsers is someone $me; PasswordAuthentication is yes"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $item ($problems; another file, or a Match block, sets them first, which sudo grep -ri <setting> /etc/ssh finds)"
assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off (PasswordAuthentication is yes)"
# The step checks them once it writes the drop-in
rm "$SSHD_DROP_IN"
: > "$STUB_LOG"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sshd doesn't take these settings from $SSHD_DROP_IN, since another file, or a Match block, sets them first:
    AllowUsers is someone $me
    PasswordAuthentication is yes"
assert_file_contains "$STUB_LOG" "sudo sshd -T"
assert_eq "PasswordAuthentication yes
AllowUsers someone" "$(cat "$SANDBOX/sshd_config.d/00-local.conf")" "the other drop-in"
# Password logins stay on, so the step doesn't say they're off
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/00-local.conf" "$SANDBOX/sshd_config.d/50-cloud-init.conf"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $item"
# A Match block for you counts too: sshd -T applies it for a login by you from this machine
printf '%s\n' "Match User $me" "    PasswordAuthentication yes" > "$SANDBOX/sshd_config.d/99-match.conf"
: > "$STUB_LOG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $item (PasswordAuthentication is yes;"
assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=127.0.0.1,addr=127.0.0.1"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "    PasswordAuthentication is yes"
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/99-match.conf"
# So does a Match block for an address: one in a private range, the tailnet's, or one the Match
# line names, such as a sub-range or an outside address. The problem names the addresses it applies
# to.
assert_exit 0 status
for match in "192.168.1.1 192.168.1.1" "100.64.0.1 100.64.0.1" "203.0.113.7 203.0.113.7" \
    "192.168.5.0/24 192.168.5.1" "!10.9.9.9,192.168.7.0/24 192.168.7.1"; do
    addr="${match##* }"
    printf '%s\n' "Match Address ${match% *}" "    PasswordAuthentication yes" > "$SANDBOX/sshd_config.d/99-match.conf"
    : > "$STUB_LOG"
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    $item (PasswordAuthentication is yes for $addr;"
    assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off (PasswordAuthentication is yes for $addr)"
    assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=$addr,addr=$addr"
done
assert_file_not_contains "$STUB_LOG" "addr=10.9.9.9"
# A wildcard pattern samples an address sshd parses; an IPv6 one short of 8 groups gets a ::
printf '%s\n' "Match Address fd00:*" "    PasswordAuthentication yes" > "$SANDBOX/sshd_config.d/99-match.conf"
: > "$STUB_LOG"
assert_exit 0 status
assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=fd00:1::1,addr=fd00:1::1"
rm "$SANDBOX/sshd_config.d/99-match.conf"
for match in "10.* 10.1" "* 1" "192.168.1.? 192.168.1.1" "fd00::/8 fd00::1" "fd00::* fd00::1" \
    "fd00:*:1 fd00:1::1:1" "2001:db8:0:0:0:0:0:* 2001:db8:0:0:0:0:0:1" "fe80::1 fe80::1"; do
    assert_eq "${match##* }" "$(range_sample "${match% *}")" "range_sample ${match% *}"
done
# This SSH session's client is checked too
export SSH_CONNECTION="198.51.100.4 51000 192.168.1.5 22"
: > "$STUB_LOG"
assert_exit 0 status
unset SSH_CONNECTION
assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=198.51.100.4,addr=198.51.100.4"
# Another setting sshd doesn't take fails the step, but password logins went off when sshd
# reloaded, so it says so
echo "PermitRootLogin yes" > "$SANDBOX/sshd_config.d/00-local.conf"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "    PermitRootLogin is yes"
assert_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/00-local.conf"
# sshd -T failing after the reload leaves the settings unchecked: the step fails, keeps the new
# drop-in, which sshd took, and says password logins are off. With ufw off, the SSH ports can't be
# read either, so the firewall is left as it is.
touch "$SANDBOX/sshd-T-fails"
rm "$SSHD_DROP_IN" "$SANDBOX/ufw-on"
: > "$STUB_LOG"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sudo sshd -T -C user=$me,host=127.0.0.1,addr=127.0.0.1 failed, so whether sshd takes $SSHD_DROP_IN is
  unchecked"
assert_eq "$(DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in when sshd -T fails"
assert_contains "$RUN_OUTPUT" "Password logins are off now"
assert_contains "$RUN_OUTPUT" "Couldn't read the SSH ports with sudo sshd -T, so the firewall is left unchanged"
assert_file_not_contains "$STUB_LOG" "ufw default"
assert_file_not_contains "$STUB_LOG" "ufw allow"
assert_file_not_contains "$STUB_LOG" "ufw --force enable"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unverified $item (sudo sshd -T -C user=$me,host=127.0.0.1,addr=127.0.0.1 failed; run it to see why)"
rm "$SANDBOX/sshd-T-fails"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 0 main
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $item"
# Without cached sudo credentials, sshd -T can't run: unverified
not_cached_sudo
: > "$STUB_LOG"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified $item (the effective values need sudo -v; run sudo -v, then status, to check them)"
assert_file_not_contains "$STUB_LOG" "sshd -T"
# Nor before sshd first ran, which creates $SSHD_RUN_DIR
stub_sudo_exec
rmdir "$SSHD_RUN_DIR"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified $item (sshd -T needs $SSHD_RUN_DIR, which the first SSH connection creates)"
mkdir "$SSHD_RUN_DIR"
not_cached_sudo
test_done
