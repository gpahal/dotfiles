#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions
set -euo pipefail

# The ubuntu step's cloud-init, cups-browsed, and Wi-Fi items: power save off, and a warning for a
# Wi-Fi connection that waits for a login. The fixture's NetworkManager stub merges its drop-ins as
# NetworkManager does, Ubuntu's turning power save on.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
# cups-browsed is enabled, as on a fresh install, until masked
stub_systemctl 'case "$*" in
    "is-enabled cups-browsed.service") cat "'"$SANDBOX"'/cups-browsed" 2> /dev/null || echo enabled; exit 0 ;;
    "mask --now cups-browsed.service") echo masked > "'"$SANDBOX"'/cups-browsed"; exit 0 ;;
esac'

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    cloud-init off"
assert_contains "$RUN_OUTPUT" "missing    cups-browsed masked"
assert_contains "$RUN_OUTPUT" "missing    Wi-Fi power save off"

# Declined: nothing changes
answer no
: > "$STUB_LOG"
assert_exit 0 main
[ ! -e "$CLOUD_INIT_DISABLED" ] || fail "cloud-init was turned off though sudo was declined"
[ ! -e "$WIFI_POWERSAVE_CONF" ] || fail "the Wi-Fi drop-in was written though sudo was declined"
assert_file_not_contains "$STUB_LOG" "mask --now"

# Accepted: it turns each off, and Wi-Fi power save now, on the Wi-Fi device only
answer yes
ubuntu_step_set_up
[ -e "$CLOUD_INIT_DISABLED" ] || fail "cloud-init wasn't turned off"
assert_file_contains "$STUB_LOG" "systemctl mask --now cups-browsed.service"
assert_file_contains "$STUB_LOG" "nmcli general reload conf"
assert_file_contains "$STUB_LOG" "iw dev wlp5s0 set power_save off"
assert_file_not_contains "$STUB_LOG" "iw dev enp6s0"

# A second run changes nothing
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "mask --now"
assert_file_not_contains "$STUB_LOG" "nmcli general reload"
assert_file_not_contains "$STUB_LOG" "iw dev"

# A drop-in sorting later that turns power save back on shows, though the step's file is in place
later="$(dirname "$WIFI_POWERSAVE_CONF")/zz-powersave-on.conf"
printf '%s\n' "[connection]" "wifi.powersave = 3" > "$later"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Wi-Fi power save off"
rm "$later"

# Without iw, the drop-in still applies when Wi-Fi next connects
rm "$WIFI_POWERSAVE_CONF" "$STUB_DIR/iw"
ubuntu_step_load
: > "$STUB_LOG"
assert_exit 0 main
assert_exit 0 main --status

# Not installed counts as off; in a VM, cloud-init is left alone, as it may set up the network
rm "$CLOUD_INIT_DISABLED" "$SANDBOX/cups-browsed"
stub dpkg-query '[ "${*: -1}" == cloud-init ] || [ "${*: -1}" == cups-browsed ] || echo "install ok installed"'
assert_exit 0 main --status
stub dpkg-query 'echo "install ok installed"'
stub systemd-detect-virt
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "cloud-init"
[ ! -e "$CLOUD_INIT_DISABLED" ] || fail "cloud-init was turned off in a VM"

# --- Wi-Fi that connects only after a login ---
stub nmcli 'case "$*" in
    "-t -e no -f UUID,TYPE,NAME connection show --active") echo "4444-dddd:802-11-wireless:Office" ;;
    "-g connection.permissions connection show uuid 4444-dddd") echo "" ;;
    "-g 802-11-wireless-security.psk-flags connection show uuid 4444-dddd") cat "'"$SANDBOX"'/flags" ;;
esac'
for flags in "1 (agent-owned)" "2 (not-saved)" "3 (agent-owned, not-saved)"; do
    echo "$flags" > "$SANDBOX/flags"
    run warn_wifi_needs_login
    assert_contains "$RUN_OUTPUT" 'Wi-Fi "Office" only connects after you log in'
done
assert_exit 1 wifi_connects_at_boot 4444-dddd
for flags in "0 (none)" "4 (not-required)" ""; do
    echo "$flags" > "$SANDBOX/flags"
    run warn_wifi_needs_login
    assert_eq "" "$RUN_OUTPUT" "the warning for psk-flags \"$flags\""
done
assert_exit 0 wifi_connects_at_boot 4444-dddd

# nmcli -e no leaves a colon or a backslash in the name unescaped
stub nmcli 'case "$*" in
    "-t -e no -f UUID,TYPE,NAME connection show --active") printf "%s\n" "1111-aaaa:802-3-ethernet:Wired" \
        "2222-bbbb:802-11-wireless:Home:5G" "3333-cccc:802-11-wireless:Back\\slash" ;;
    "-g connection.permissions connection show uuid 2222-bbbb") echo "user:me" ;;
    "-g 802-11-wireless-security.psk-flags connection show uuid 3333-cccc") echo "1 (agent-owned)" ;;
esac'
run warn_wifi_needs_login
assert_contains "$RUN_OUTPUT" 'Wi-Fi "Home:5G" only connects after you log in'
assert_contains "$RUN_OUTPUT" 'sudo nmcli --ask connection up uuid 2222-bbbb'
assert_contains "$RUN_OUTPUT" 'Wi-Fi "Back\slash" only connects after you log in'
assert_contains "$RUN_OUTPUT" 'sudo nmcli --ask connection up uuid 3333-cccc'
assert_not_contains "$RUN_OUTPUT" "Wired"
test_done
