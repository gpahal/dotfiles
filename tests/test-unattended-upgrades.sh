#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
stub_sudo_exec

load_script chrome/install.sh
as_os ubuntu
UNATTENDED_CONF="$SANDBOX/52dotfiles-google-chrome"
printf '%s\n' "$UNATTENDED_CONTENT" > "$UNATTENDED_CONF"
GOOGLE_SOURCES="$SANDBOX/google-chrome.sources"
# The key Google's .deb installed, with the pinned fingerprint
GOOGLE_KEYRING="$SANDBOX/google-chrome.gpg"
touch "$GOOGLE_KEYRING"
stub gpg 'printf "pub:-\nfpr:::::::::%s:\n" "'"$GOOGLE_KEY_FPR"'"'
# Firefox is already gone, as the chrome step leaves it
stub dpkg-query '[ "${!#}" == firefox ] || echo "install ok installed"'
stub snap 'exit 1'
periodic() {
    stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"'"$1"'\";"'
}

# apt-config is a sentinel here, so status mustn't reach it
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Google's apt source"
assert_not_contains "$RUN_OUTPUT" "unattended-upgrades runs daily"

printf 'Types: deb\nURIs: https://dl.google.com/linux/chrome-stable/deb/\nSuites: stable\nComponents: main\n' > "$GOOGLE_SOURCES"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Google's apt source"

# apt.systemd.daily takes always or an interval (bare number = days); up to a day counts as daily
# shellcheck source=../ubuntu/lib/updates.sh
source "$REPO_DIR/ubuntu/lib/updates.sh"
# ubuntu/install.sh sets it; absent here
AUTO_UPGRADES_CONF="$SANDBOX/20auto-upgrades"
for value in always 1d 24h 90m 3600s; do
    periodic "$value"
    assert_exit 0 unattended_upgrades_on
done
for value in 0 0h 2 2d 25h never ""; do
    periodic "$value"
    assert_exit 1 unattended_upgrades_on
done
stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"always\";"
echo "APT::Periodic::Unattended-Upgrade \"1\";"'
assert_exit 0 unattended_upgrades_on

# Enable "0", or Update-Package-Lists 0 or unset, turns it off
for config in \
    'APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' \
    'APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "1";' \
    'APT::Periodic::Unattended-Upgrade "1";'; do
    printf '%s\n' "$config" > "$SANDBOX/periodic-config"
    stub_apt_config 'cat "'"$SANDBOX"'/periodic-config"'
    assert_exit 1 unattended_upgrades_on
done
test_done
