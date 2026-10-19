#!/bin/bash
set -euo pipefail

# sshd_settings_problems against the real sshd -T, which only parses the config (no daemon).

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
# Includes the drop-ins before any Match block, as Ubuntu's does
sshd_config() {
    printf '%s\n' "Include $(dirname "$SSHD_DROP_IN")/*.conf" "$@" > "$SSHD_CONFIG"
}
sshd_config
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

problems_are() {
    if ! sshd_settings_problems "$DROP_IN" -n; then
        fail "sshd -T failed for $2, with -C $SSHD_FAILED_SPEC"
        return 0
    fi
    assert_eq "$1" "$SSHD_PROBLEMS" "the settings sshd doesn't take, $2"
}

problems_are "" "with the drop-in alone"
assert_file_contains "$STUB_LOG" "sudo -n $SSHD_BIN -T -C user=$me,host=127.0.0.1,addr=127.0.0.1"

# sshd matches address patterns as strings, so fd00:* catches fd00::/8's sample too
sshd_config "Match Address fd00:*" "    PasswordAuthentication yes"
problems_are "PasswordAuthentication is yes for fd00::1, fd00:1::1" "with a Match block for fd00:*"
sshd_config "Match Address 192.168.5.0/24,!10.9.9.9" "    PasswordAuthentication yes"
problems_are "PasswordAuthentication is yes for 192.168.5.1" "with a Match block for a /24"

sshd_config "Match User $me" "    KbdInteractiveAuthentication yes"
problems_are "KbdInteractiveAuthentication is yes" "with a Match block for you"
sshd_config

# sshd keeps the first value of each setting but merges every AllowUsers line
printf '%s\n' "PasswordAuthentication yes" "AllowUsers someone" > "$(dirname "$SSHD_DROP_IN")/00-local.conf"
problems_are "AllowUsers is someone $me
PasswordAuthentication is yes" "with an earlier drop-in"
rm "$(dirname "$SSHD_DROP_IN")/00-local.conf"
echo "PasswordAuthentication yes" > "$(dirname "$SSHD_DROP_IN")/50-cloud-init.conf"
problems_are "" "with a later drop-in"
echo "AllowUsers someone" >> "$(dirname "$SSHD_DROP_IN")/50-cloud-init.conf"
problems_are "AllowUsers is $me someone" "with a later drop-in that allows another user"
test_done
