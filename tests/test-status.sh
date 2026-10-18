#!/bin/bash
set -euo pipefail

# The unverified status state doesn't count as needing attention, and status reads root-only
# settings with sudo -n only when sudo credentials are cached, never asking.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
# Status reports read apt's periodic settings
stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"1\";"'

# status_result: unverified alone exits 0; missing or unknown exit 3
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

# sudo stubs: one whose credentials aren't cached, so sudo -n fails, and one whose are. The cached
# one runs only commands that read; any other it records in $SANDBOX/mutations and fails, since
# status must write nothing. A test can't make a file only root reads, so for `cat <file>` of an
# unreadable file it prints <file>.root instead.
sudo_not_cached() {
    stub sudo '[ "$1" != -n ] || exit 1; echo "sudo asked for a password" >&2; exit 1'
}
sudo_cached_stub() {
    stub sudo '[ "$1" != -n ] || shift
case "$1 ${2:-}" in
    "true "* | "cat "* | "test "* | "sshd -T" | "ufw status" | "ufw show") ;;
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

# Every sudo a status run made was sudo -n, so none could ask for a password, and none wrote
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

# The ubuntu step, on a machine where everything else is set up. ufw's and linger's state come
# from files under /etc and /var, so those two checks are replaced.
load_script ubuntu/install.sh
is_ubuntu() { true; }
lingering() { true; }
# test-ubuntu-step.sh covers smartd with its hook, the locale, unattended-upgrades with its
# conffile options, the packages apt holds back, and the health alerts' worktree check, and
# test-diagnostics-ubuntu.sh SMART health and firmware updates
smartd_enabled() { true; }
smartd_hook_installed() { true; }
keep_conffiles_written() { true; }
status_held_back() { :; }
in_git_worktree() { false; }
status_smart() { :; }
status_firmware() { :; }
# test-ubuntu-ups.sh covers the UPS
ups_todo() { :; }
status_ups() { :; }
warn_no_ups() { :; }
# The kernel has the sysctl settings, which test-ubuntu-step.sh covers
sysctl_in_effect() { true; }
locale_installed() { true; }
unattended_upgrades_running() { true; }
# test-ubuntu-step.sh covers apt's timers, sshd at boot, a pending reboot, and the health alerts'
# units and their reload
apt_timers_enabled() { true; }
health_units_written() { true; }
health_units_loaded() { true; }
sshd_enabled() { true; }
# shellcheck disable=SC2034 # the step reads it
REBOOT_REQUIRED="$SANDBOX/no-reboot-required"
ufw_enabled() { true; }
UFW_DEFAULTS="$SANDBOX/default-ufw"
echo IPV6=yes > "$UFW_DEFAULTS"
stub systemctl '[ "$1" != is-enabled ] || echo masked'
stub dpkg-query 'echo "install ok installed"'
# Tailscale's apt source is the one the step writes
tailscale_list_line > "$TAILSCALE_LIST"
stub tailscale 'case "$1" in
    debug) echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\"}" ;;
    status) echo "{\"BackendState\": \"Running\"}" ;;
esac'
# The rest is set up too, through sandbox paths
SSHD_RUN_DIR="$SANDBOX/run-sshd"
mkdir -p "$SSHD_RUN_DIR"
SLEEP_CONF="$SANDBOX/10-sleep.conf"
printf '%s\n' "$SLEEP_CONF_CONTENT" > "$SLEEP_CONF"
SYSCTL_CONF="$SANDBOX/90-sysctl.conf"
printf '%s\n' "$SYSCTL_CONTENT" > "$SYSCTL_CONF"
stub nmcli
# sshd -T prints the port, and the drop-in's settings as sshd takes them
stub sshd '[ "$1" != -T ] || { echo "port 22"
    { cat "'"$SANDBOX"'/10-dotfiles.conf" 2> /dev/null || cat "'"$SANDBOX"'/10-dotfiles.conf.root"; } | awk "{ print tolower(\$1), \$2 }"; }'
ufw_has_rules() {
    stub ufw 'cat << EOF
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       10.0.0.0/8
22/tcp                     ALLOW       192.168.0.0/16
22/tcp                     ALLOW       fd00::/8
22/tcp                     ALLOW       fe80::/10
Anywhere on tailscale0     ALLOW       Anywhere
41641/udp                  ALLOW       Anywhere
EOF'
}
ufw_has_rules
SSHD_DROP_IN="$SANDBOX/10-dotfiles.conf"
# Password logins already off
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
mkdir -p "$(dirname "$HOMEBREW_ENV_CONF")"
cp "$HOMEBREW_ENV_SRC" "$HOMEBREW_ENV_CONF"
: > "$STUB_LOG"

# Without cached credentials the ufw rules are unverified, and the report needs no attention
sudo_not_cached
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified ufw rules"
assert_contains "$RUN_OUTPUT" "sudo -v"
assert_not_contains "$RUN_OUTPUT" "unknown"
assert_not_contains "$RUN_OUTPUT" "missing"
no_prompting_sudo

# With cached credentials they're checked: ok when they're there, missing when one isn't
sudo_cached_stub
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         ufw rules"
assert_not_contains "$RUN_OUTPUT" "unverified"
no_prompting_sudo
stub ufw 'printf "Status: active\n\nAnywhere on tailscale0     ALLOW       Anywhere\n"'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw rules"
no_prompting_sudo

# Without $SSHD_RUN_DIR, sshd -T can't list the ports, and status doesn't create it: the rules are
# unverified, saying why
ufw_has_rules
rmdir "$SSHD_RUN_DIR"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified ufw rules"
assert_contains "$RUN_OUTPUT" "first SSH connection"
[ ! -e "$SSHD_RUN_DIR" ] || fail "status created $SSHD_RUN_DIR"
no_prompting_sudo
mkdir -p "$SSHD_RUN_DIR"

# Without openssh-server, the rules are missing, and it doesn't say to run sudo -v
stub dpkg-query 'exit 1'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw rules"
assert_contains "$RUN_OUTPUT" "openssh-server isn't installed"
assert_not_contains "$RUN_OUTPUT" "sudo -v"
no_prompting_sudo
stub dpkg-query 'echo "install ok installed"'

# An sshd drop-in only root can read is unverified without cached credentials, and read with
# sudo -n with them. Skipped when running as root, which reads any file.
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

# The docker step: a daemon.json only root can read
load_script docker/install.sh
is_macos() { false; }
# Docker's packages are installed
stub dpkg-query 'case "${!#}" in docker-ce | docker-ce-cli | containerd.io | docker-*-plugin) echo "install ok installed" ;; esac'
stub id 'case "$1" in -un) echo me ;; -nG) echo "me docker" ;; esac'
stub systemctl 'exit 1'
# Docker's apt source lists this release
OS_RELEASE="$SANDBOX/os-release"
printf '%s\n' ID=ubuntu VERSION_CODENAME=resolute > "$OS_RELEASE"
APT_SOURCES_DIR="$SANDBOX/apt/sources.list.d"
DOCKER_SOURCES="$APT_SOURCES_DIR/docker.sources"
mkdir -p "$APT_SOURCES_DIR"
stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
docker_sources > "$DOCKER_SOURCES"
DOCKER_DAEMON_CONFIG="$SANDBOX/daemon.json"
echo '{"log-driver": "local", "live-restore": true, "ip": "127.0.0.1", "default-network-opts": {"bridge": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}}}' > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$DOCKER_DAEMON_CONFIG.root"
chmod 000 "$DOCKER_DAEMON_CONFIG"
if [ ! -r "$DOCKER_DAEMON_CONFIG" ]; then
    : > "$STUB_LOG"
    sudo_not_cached
    run status
    assert_contains "$RUN_OUTPUT" "unverified log-driver, live-restore, and localhost-only published ports in $DOCKER_DAEMON_CONFIG"
    assert_not_contains "$RUN_OUTPUT" "unknown"
    no_prompting_sudo
    sudo_cached_stub
    run status
    assert_contains "$RUN_OUTPUT" "ok         log-driver, live-restore, and localhost-only published ports in $DOCKER_DAEMON_CONFIG"
    no_prompting_sudo
    echo '{}' > "$DOCKER_DAEMON_CONFIG.root"
    run status
    assert_contains "$RUN_OUTPUT" "missing    log-driver, live-restore, and localhost-only published ports in $DOCKER_DAEMON_CONFIG"
    no_prompting_sudo
fi
chmod 644 "$DOCKER_DAEMON_CONFIG"

# The macos step: a sandboxed app's default that defaults can't read is unverified, and an
# unreadable default of any other app is missing
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
