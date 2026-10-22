#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions
set -euo pipefail

# The ubuntu step's cloud-init, cups-browsed, and Wi-Fi power save items. The fixture's
# NetworkManager stub merges its drop-ins as NetworkManager does, Ubuntu's turning power save on.

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

assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    cloud-init off, since it only sets up a fresh install ($CLOUD_INIT_DISABLED)"
assert_contains "$RUN_OUTPUT" "missing    cups-browsed masked, so network printers aren't added by themselves"
assert_contains "$RUN_OUTPUT" "missing    Wi-Fi power save off, so SSH over Wi-Fi doesn't lag ($WIFI_POWERSAVE_CONF)"

# Declined: nothing changes
answer no
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turn off cloud-init, which only sets up a fresh install: write $CLOUD_INIT_DISABLED"
assert_contains "$RUN_OUTPUT" "Mask cups-browsed, which adds network printers by itself; cups still prints"
assert_contains "$RUN_OUTPUT" "Turn off Wi-Fi power save, which makes SSH over Wi-Fi lag: write $WIFI_POWERSAVE_CONF"
[ ! -e "$CLOUD_INIT_DISABLED" ] || fail "cloud-init was turned off though sudo was declined"
[ ! -e "$WIFI_POWERSAVE_CONF" ] || fail "the Wi-Fi drop-in was written though sudo was declined"
assert_file_not_contains "$STUB_LOG" "mask --now"

# Accepted: it turns each off, and Wi-Fi power save now, on the Wi-Fi device only
answer yes
ubuntu_step_set_up
assert_file_contains "$CLOUD_INIT_DISABLED" "# From the dotfiles ubuntu step"
assert_file_contains "$STUB_LOG" "systemctl mask --now cups-browsed.service"
assert_file_contains "$WIFI_POWERSAVE_CONF" "wifi.powersave = 2"
assert_file_contains "$STUB_LOG" "nmcli general reload conf"
assert_file_contains "$STUB_LOG" "iw dev wlp5s0 set power_save off"
assert_file_not_contains "$STUB_LOG" "iw dev enp6s0"
assert_contains "$RUN_OUTPUT" "ok         cloud-init off, since it only sets up a fresh install ($CLOUD_INIT_DISABLED)"
assert_contains "$RUN_OUTPUT" "ok         cups-browsed masked, so network printers aren't added by themselves"
assert_contains "$RUN_OUTPUT" "ok         Wi-Fi power save off, so SSH over Wi-Fi doesn't lag ($WIFI_POWERSAVE_CONF)"

# A second run changes nothing
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "mask --now"
assert_file_not_contains "$STUB_LOG" "nmcli general reload"
assert_file_not_contains "$STUB_LOG" "iw dev"

# A drop-in sorting later that turns power save back on shows, though the step's file is in place
later="$(dirname "$WIFI_POWERSAVE_CONF")/zz-powersave-on.conf"
printf '%s\n' "[connection]" "wifi.powersave = 3" > "$later"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Wi-Fi power save off, so SSH over Wi-Fi doesn't lag ($WIFI_POWERSAVE_CONF)"
rm "$later"

# Without iw, the drop-in still applies when Wi-Fi next connects
rm "$WIFI_POWERSAVE_CONF" "$STUB_DIR/iw"
ubuntu_step_load
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Wi-Fi power save goes off when Wi-Fi next connects; install iw to turn it off now."
assert_file_contains "$WIFI_POWERSAVE_CONF" "wifi.powersave = 2"

# Not installed counts as off; in a VM, cloud-init is left alone, as it may set up the network
rm "$CLOUD_INIT_DISABLED" "$SANDBOX/cups-browsed"
stub dpkg-query '[ "${*: -1}" == cloud-init ] || [ "${*: -1}" == cups-browsed ] || echo "install ok installed"'
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         cloud-init off"
assert_contains "$RUN_OUTPUT" "ok         cups-browsed masked"
stub dpkg-query 'echo "install ok installed"'
stub systemd-detect-virt
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "cloud-init"
[ ! -e "$CLOUD_INIT_DISABLED" ] || fail "cloud-init was turned off in a VM"

test_done
