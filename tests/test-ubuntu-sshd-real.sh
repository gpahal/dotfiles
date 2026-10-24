#!/bin/bash

# sshd_settings_problems against the real sshd -T, which only parses the config (no daemon).

REAL_SSHD="$(PATH=/usr/sbin:/usr/bin:/sbin:/bin command -v sshd || true)"
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

[ -n "$REAL_SSHD" ] || skip "sshd isn't installed"

# DOTFILES_SSH_KEY_ONLY counts only in a VM
stub systemd-detect-virt
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
        fail "sshd -T failed for $2"
        return 0
    fi
    assert_eq "$1" "$SSHD_PROBLEMS" "the settings sshd doesn't take, $2"
}

problems_are "" "with the drop-in alone"
assert_file_contains "$STUB_LOG" "sudo -n $SSHD_BIN -T"
assert_eq "" "$SSHD_MATCH_FILES" "the files with a Match block, with none"

# sshd -T leaves out Match blocks, so the file with one is named instead
sshd_config "Match User $me" "    KbdInteractiveAuthentication yes"
problems_are "" "with a Match block for you"
assert_eq "$SSHD_CONFIG" "$SSHD_MATCH_FILES" "the files with a Match block"
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
