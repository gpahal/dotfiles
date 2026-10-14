#!/bin/bash
# The steps' functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The chrome step's status checks Google's apt source and allowed origins for unattended upgrades.
# The ubuntu step checks the daily schedule: unattended_upgrades_on reads apt's periodic settings
# as apt.systemd.daily does. The ubuntu step's simulated upgrade counts phased updates.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
stub sudo 'exec env "$@"'

# --- chrome ---
load_script chrome/install.sh
is_macos() { false; }
is_ubuntu() { true; }
UNATTENDED_CONF="$SANDBOX/52dotfiles-google-chrome"
printf '%s\n' "$UNATTENDED_CONTENT" > "$UNATTENDED_CONF"
APT_SOURCES_DIR="$SANDBOX/sources.list.d"
mkdir -p "$APT_SOURCES_DIR"
stub dpkg-query 'echo "install ok installed"'
periodic() {
    stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"'"$1"'\";"'
}

# Google's source is missing. apt-config is still a sentinel, so status doesn't read it.
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Google's apt source"
assert_not_contains "$RUN_OUTPUT" "unattended-upgrades runs daily"

# Either name of Google's source counts
printf 'deb https://dl.google.com/linux/chrome/deb stable main\n' > "$APT_SOURCES_DIR/google-chrome.list"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Google's apt source"
rm "$APT_SOURCES_DIR/google-chrome.list"
printf 'Types: deb\nURIs: https://dl.google.com/linux/chrome/deb\nSuites: stable\nComponents: main\n' > "$APT_SOURCES_DIR/google-chrome.sources"
assert_exit 0 status

# apt.systemd.daily also takes always, and an interval in s, m, h, or d, which a bare number means.
# Any interval up to a day counts as daily.
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

# Unattended-Upgrade alone isn't enough: Enable "0", or Update-Package-Lists 0 or unset, turns it
# off
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

# --- ubuntu: packages apt holds back ---
# Phased updates count as upgradable, so apt 2.7 doesn't list them as kept back every day
load_script ubuntu/install.sh
stub apt-get 'printf "%s\n" "The following packages have been kept back:" "  foo bar" "0 upgraded."'
: > "$STUB_LOG"
assert_eq "foo
bar" "$(held_back_packages)" "the held-back packages"
assert_file_contains "$STUB_LOG" "apt-get -s -o APT::Get::Upgrade-Allow-New=true -o APT::Get::Always-Include-Phased-Updates=true upgrade"
test_done
