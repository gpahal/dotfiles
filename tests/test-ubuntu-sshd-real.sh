#!/bin/bash
set -euo pipefail

# The ubuntu step's check that sshd takes its drop-in's settings (sshd_settings_problems), against
# the real sshd -T where sshd is installed, rather than tests/ubuntu-step-fixture.sh's model of it:
# the drop-in sshd takes, a Match block for an address pattern or for you, and an earlier file
# that sets the settings first. sshd -T only parses the config and prints the settings it would
# run with, so no daemon starts. It reads a config and host key in the sandbox. On Linux it needs
# /run/sshd, which openssh-server's service creates.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

REAL_SSHD="$(PATH=/usr/sbin:/usr/bin:/sbin:/bin command -v sshd)" || skip "sshd isn't installed"

setup_sandbox
load_script ubuntu/install.sh
ubuntu_sandbox_paths
mkdir -p "$SSHD_RUN_DIR" "$(dirname "$SSHD_DROP_IN")"
ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/host-key"
# sshd's own config includes the drop-ins, as Ubuntu's does, before any Match block a test adds
sshd_config() {
    printf '%s\n' "Include $(dirname "$SSHD_DROP_IN")/*.conf" "$@" > "$SSHD_CONFIG"
}
sshd_config
# The step runs sshd through sudo, which runs it as you here, with the sandbox's config and key
real_sshd=("$REAL_SSHD" -f "$SSHD_CONFIG" -h "$SANDBOX/host-key")
stub sshd "exec $(printf '%q ' "${real_sshd[@]}")\"\$@\""
stub_sudo_exec
unset SSH_CONNECTION
me="$(id -un)"
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in "" > "$SSHD_DROP_IN"
DROP_IN="$(cat "$SSHD_DROP_IN")"
if ! out="$("${real_sshd[@]}" -T -C "user=$me,host=127.0.0.1,addr=127.0.0.1" 2>&1 < /dev/null)"; then
    skip "sshd -T can't run here: $(head -n 1 <<< "$out")"
fi

# problems_are <expected> <what>: the problems sshd_settings_problems finds with the drop-in
problems_are() {
    if ! sshd_settings_problems "$DROP_IN" -n; then
        fail "sshd -T failed for $2, with -C $SSHD_FAILED_SPEC"
        return 0
    fi
    assert_eq "$1" "$SSHD_PROBLEMS" "the settings sshd doesn't take, $2"
}

# The drop-in alone: sshd takes every setting
problems_are "" "with the drop-in alone"
assert_file_contains "$STUB_LOG" "sudo -n $SSHD_BIN -T -C user=$me,host=127.0.0.1,addr=127.0.0.1"

# sshd matches an address pattern as a string, so fd00:* takes in the sample of fd00::/8 too, and
# that of the pattern itself
sshd_config "Match Address fd00:*" "    PasswordAuthentication yes"
problems_are "PasswordAuthentication is yes for fd00::1, fd00:1::1" "with a Match block for fd00:*"
# A range, and a list with a negation
sshd_config "Match Address 192.168.5.0/24,!10.9.9.9" "    PasswordAuthentication yes"
problems_are "PasswordAuthentication is yes for 192.168.5.1" "with a Match block for a /24"

# A Match block for you applies from every address
sshd_config "Match User $me" "    KbdInteractiveAuthentication yes"
problems_are "KbdInteractiveAuthentication is yes" "with a Match block for you"
sshd_config

# An earlier drop-in sets them first, and sshd adds every AllowUsers line's users
printf '%s\n' "PasswordAuthentication yes" "AllowUsers someone" > "$(dirname "$SSHD_DROP_IN")/00-local.conf"
problems_are "AllowUsers is someone $me
PasswordAuthentication is yes" "with an earlier drop-in"
# A later one loses to the drop-in, but for AllowUsers, whose users it adds
rm "$(dirname "$SSHD_DROP_IN")/00-local.conf"
echo "PasswordAuthentication yes" > "$(dirname "$SSHD_DROP_IN")/50-cloud-init.conf"
problems_are "" "with a later drop-in"
echo "AllowUsers someone" >> "$(dirname "$SSHD_DROP_IN")/50-cloud-init.conf"
problems_are "AllowUsers is $me someone" "with a later drop-in that allows another user"
test_done
