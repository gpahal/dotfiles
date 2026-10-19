#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
load_script lib/common.sh
stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"1\";"'

report() {
    local state
    for state in "$@"; do
        status_item "$state" "item"
    done
    status_result
}
assert_exit 0 report ok unverified skipped
assert_contains "$RUN_OUTPUT" "  unverified item"
assert_exit 3 report ok unverified unknown
assert_exit 3 report unverified missing

# The cached stub records anything but a read in $SANDBOX/mutations. A test can't make a file
# only root reads, so `cat <file>` of an unreadable file prints <file>.root.
sudo_not_cached() {
    stub sudo '[ "$1" != -n ] || exit 1; echo "sudo asked for a password" >&2; exit 1'
}
sudo_cached_stub() {
    stub sudo '[ "$1" != -n ] || shift
case "$1 ${2:-}" in
    "true "* | "cat "* | "test "* | *"/sshd -T" | "ufw status" | "ufw show") ;;
    *) echo "$*" >> "'"$SANDBOX"'/mutations"; exit 1 ;;
esac
[ "$1" != cat ] || [ -r "$2" ] || exec cat "$2.root"
exec "$@"'
}

sudo_not_cached
assert_exit 1 sudo_cached
sudo_cached_stub
assert_exit 0 sudo_cached
assert_file_contains "$STUB_LOG" "sudo -n true"

no_prompting_sudo() {
    if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
        fail "status ran sudo without -n:"
        _show "$(grep '^sudo' "$STUB_LOG")"
    fi
    if [ -s "$SANDBOX/mutations" ]; then
        fail "status ran sudo to change something:"
        _show "$(cat "$SANDBOX/mutations")"
    fi
    : > "$STUB_LOG"
    : > "$SANDBOX/mutations"
}

load_script ubuntu/install.sh
ubuntu_sandbox_paths
as_os ubuntu
replace_fn lingering true
# Covered by test-ubuntu-step.sh, test-diagnostics-ubuntu.sh, test-ubuntu-ups.sh, and
# test-ubuntu-system.sh
replace_fn smartd_enabled true
replace_fn smartd_hook_installed true
replace_fn keep_conffiles_written true
replace_fn status_held_back :
replace_fn in_git_worktree false
replace_fn status_smart :
replace_fn status_firmware :
replace_fn ups_todo :
replace_fn status_ups :
replace_fn warn_no_ups :
replace_fn sysctl_in_effect true
replace_fn locale_installed true
replace_fn unattended_upgrades_running true
replace_fn apt_timers_enabled true
replace_fn health_units_written true
replace_fn health_units_loaded true
replace_fn sshd_enabled true
replace_fn ufw_enabled true
echo IPV6=yes > "$UFW_DEFAULTS"
stub systemctl '[ "$1" != is-enabled ] || echo masked'
stub systemd-detect-virt 'exit 1'
stub dpkg-query 'echo "install ok installed"'
tailscale_list_line > "$TAILSCALE_LIST"
stub tailscale 'case "$1" in
    debug) echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\"}" ;;
    status) echo "{\"BackendState\": \"Running\"}" ;;
esac'
mkdir -p "$SSHD_RUN_DIR" "$(dirname "$SLEEP_CONF")" "$(dirname "$SYSCTL_CONF")"
printf '%s\n' "$SLEEP_CONF_CONTENT" > "$SLEEP_CONF"
printf '%s\n' "$SYSCTL_CONTENT" > "$SYSCTL_CONF"
echo "DEVICESCAN -M exec /usr/share/smartmontools/smartd-runner" > "$SMARTD_CONF"
stub nmcli
stub sshd '[ "$1" != -T ] || { echo "port 22"
    { cat "'"$SANDBOX"'/10-dotfiles.conf" 2> /dev/null || cat "'"$SANDBOX"'/10-dotfiles.conf.root"; } | awk "{ print tolower(\$1), \$2 }"; }'
ufw_has_rules() {
    ufw_status_listing > "$SANDBOX/ufw-status"
    stub ufw 'cat "'"$SANDBOX"'/ufw-status"'
}
ufw_has_rules
SSHD_DROP_IN="$SANDBOX/10-dotfiles.conf"
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
mkdir -p "$(dirname "$HOMEBREW_ENV_CONF")"
cp "$HOMEBREW_ENV_SRC" "$HOMEBREW_ENV_CONF"
: > "$STUB_LOG"

sudo_not_cached
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified ufw rules"
assert_contains "$RUN_OUTPUT" "sudo -v"
assert_not_contains "$RUN_OUTPUT" "unknown"
assert_not_contains "$RUN_OUTPUT" "missing"
no_prompting_sudo

sudo_cached_stub
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         ufw rules"
assert_not_contains "$RUN_OUTPUT" "unverified"
no_prompting_sudo
stub ufw 'printf "Status: active\n\nAnywhere on tailscale0     ALLOW       Anywhere\n"'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw rules"
no_prompting_sudo

# Without $SSHD_RUN_DIR, sshd -T can't list the ports
ufw_has_rules
rmdir "$SSHD_RUN_DIR"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified ufw rules"
assert_contains "$RUN_OUTPUT" "first SSH connection"
[ ! -e "$SSHD_RUN_DIR" ] || fail "status created $SSHD_RUN_DIR"
no_prompting_sudo
mkdir -p "$SSHD_RUN_DIR"

stub dpkg-query 'exit 1'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw rules"
assert_contains "$RUN_OUTPUT" "openssh-server isn't installed"
assert_not_contains "$RUN_OUTPUT" "sudo -v"
no_prompting_sudo
stub dpkg-query 'echo "install ok installed"'

# Skipped as root, which reads any file
ufw_has_rules
cp "$SSHD_DROP_IN" "$SSHD_DROP_IN.root"
chmod 000 "$SSHD_DROP_IN"
if [ ! -r "$SSHD_DROP_IN" ]; then
    sudo_not_cached
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "unverified $SSHD_DROP_IN"
    no_prompting_sudo
    sudo_cached_stub
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "ok         $SSHD_DROP_IN"
    no_prompting_sudo
    echo "# changed" > "$SSHD_DROP_IN.root"
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    $SSHD_DROP_IN"
    no_prompting_sudo
fi
chmod 644 "$SSHD_DROP_IN"

load_script docker/install.sh
stub pgrep 'exit 1'
as_os ubuntu
stub dpkg-query 'case "${!#}" in docker-ce | docker-ce-cli | containerd.io | docker-*-plugin) echo "install ok installed" ;; esac'
stub id 'case "$1" in -un) echo me ;; -nG) echo "me docker" ;; esac'
stub systemctl 'exit 1'
OS_RELEASE="$SANDBOX/os-release"
printf '%s\n' ID=ubuntu VERSION_CODENAME=resolute > "$OS_RELEASE"
APT_SOURCES_DIR="$SANDBOX/apt/sources.list.d"
DOCKER_SOURCES="$APT_SOURCES_DIR/docker.sources"
mkdir -p "$APT_SOURCES_DIR"
stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
docker_sources > "$DOCKER_SOURCES"
DOCKER_DAEMON_CONFIG="$SANDBOX/daemon.json"
jq "$DOCKER_DAEMON_SETTINGS" <<< '{}' > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$DOCKER_DAEMON_CONFIG.root"
chmod 000 "$DOCKER_DAEMON_CONFIG"
if [ ! -r "$DOCKER_DAEMON_CONFIG" ]; then
    : > "$STUB_LOG"
    sudo_not_cached
    run status
    assert_contains "$RUN_OUTPUT" "unverified log-driver, live-restore, localhost-only published ports, and address pools in $DOCKER_DAEMON_CONFIG"
    assert_not_contains "$RUN_OUTPUT" "unknown"
    no_prompting_sudo
    sudo_cached_stub
    run status
    assert_contains "$RUN_OUTPUT" "ok         log-driver, live-restore, localhost-only published ports, and address pools in $DOCKER_DAEMON_CONFIG"
    no_prompting_sudo
    echo '{}' > "$DOCKER_DAEMON_CONFIG.root"
    run status
    assert_contains "$RUN_OUTPUT" "missing    log-driver, live-restore, localhost-only published ports, and address pools in $DOCKER_DAEMON_CONFIG"
    no_prompting_sudo
fi
chmod 644 "$DOCKER_DAEMON_CONFIG"

# An unreadable default is unverified only for a sandboxed app

load_script macos/install.sh
stub defaults 'exit 1'
textedit_status() {
    status_default com.apple.TextEdit RichText -int 0
    status_result
}
assert_exit 3 textedit_status
assert_contains "$RUN_OUTPUT" "missing    com.apple.TextEdit RichText = 0"
mkdir -p "$HOME/Library/Containers/com.apple.TextEdit"
assert_exit 0 textedit_status
assert_contains "$RUN_OUTPUT" "unverified com.apple.TextEdit RichText = 0"
assert_contains "$RUN_OUTPUT" "Full Disk Access"
test_done
