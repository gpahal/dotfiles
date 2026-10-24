#!/bin/bash
# shellcheck disable=SC2329

# The monitor-input step, just monitor-input on both OSes, the switcher the Ubuntu service runs,
# and the hammerspoon step's m1ddc check. Fake sysfs trees stand in for USB devices and outputs.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

USB="$SANDBOX/usb"
DRM="$SANDBOX/drm"

# Usage: usb_device <name> <vendor:product> [product name]
usb_device() {
    mkdir -p "$USB/$1"
    echo "${2%%:*}" > "$USB/$1/idVendor"
    echo "${2##*:}" > "$USB/$1/idProduct"
    [ -z "${3:-}" ] || echo "$3" > "$USB/$1/product"
}

# Usage: output <card-connector> <status> [i2c bus]
output() {
    mkdir -p "$DRM/$1"
    echo "$2" > "$DRM/$1/status"
    if [ -n "${3:-}" ]; then
        mkdir -p "$SANDBOX/i2c/i2c-$3"
        ln -sfn "$SANDBOX/i2c/i2c-$3" "$DRM/$1/ddc"
    fi
}

# The scripts' paths in the sandbox, and the fake sysfs trees
monitor_input_paths() {
    sandbox_paths USB_DEVICES_DIR="$USB" DRM_DIR="$DRM" monitor-input/lib/paths.sh
}

usb_device 1-1 05e3:0610 "USB2.1 Hub"
usb_device 1-2 19f5:2620 "Air75 V3 Dongle"
output card1-HDMI-A-1 connected 4
output card1-DP-1 disconnected 5
output card1-Writeback-1 unknown

stub systemctl
stub udevadm
stub ddcutil
stub_sudo_exec

the_step() {
    load_script monitor-input/install.sh
    monitor_input_paths
    as_os ubuntu
    stub_apt_packages
    # shellcheck disable=SC2034 # apt_get_update reads it
    APT_UPDATE_RETRY_DELAY=0

    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    ddcutil"
    assert_contains "$RUN_OUTPUT" "missing    Input switcher ($MONITOR_INPUT_SCRIPT)"
    assert_contains "$RUN_OUTPUT" "info       Monitor input switching is off"

    : > "$STUB_LOG"
    answer no
    assert_exit 0 main
    assert_file_not_contains "$STUB_LOG" "apt-get"
    [ ! -e "$MONITOR_INPUT_SCRIPT" ] || fail "the switcher was installed though confirm declined"

    answer yes
    assert_exit 0 main

    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "already installed"
    assert_file_not_contains "$STUB_LOG" "sudo"
    assert_exit 0 main --status

    mkdir -p "$(dirname "$MONITOR_INPUT_CONF")"
    printf '%s\n' device=19f5:2620 input=17 other=27 connector=HDMI-A-1 > "$MONITOR_INPUT_CONF"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Monitor input switching: $MONITOR_INPUT_RULE is missing"
    mkdir -p "$(dirname "$MONITOR_INPUT_RULE")"
    : > "$MONITOR_INPUT_RULE"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         Monitor input switching on HDMI-A-1, for USB device 19f5:2620"
    rm "$DRM/card1-HDMI-A-1/ddc"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "the HDMI-A-1 connector has no DDC bus"
}
subtest the_step

setup_on_ubuntu() {
    output card1-HDMI-A-1 connected 4
    load_script monitor-input/setup.sh
    monitor_input_paths
    as_os ubuntu
    answer yes
    # Left by the_step
    rm -f "$MONITOR_INPUT_CONF" "$MONITOR_INPUT_RULE"
    mkdir -p "$(dirname "$MONITOR_INPUT_SCRIPT")"
    : > "$MONITOR_INPUT_SCRIPT"
    chmod +x "$MONITOR_INPUT_SCRIPT"

    assert_exit 2 main 19f5:2620 17
    assert_contains "$RUN_OUTPUT" "Give the Mac's input too"
    assert_exit 2 main 19f5 17 27
    assert_exit 2 main 19f5:2620 17 0x11
    assert_contains "$RUN_OUTPUT" "both 17"
    assert_exit 1 main 19f5:2620 17 27 DP-1
    assert_contains "$RUN_OUTPUT" "DP-1 isn't a connected output with DDC"
    [ ! -e "$MONITOR_INPUT_CONF" ] || fail "a rejected run saved the settings"

    assert_exit 0 main 19F5:2620 0x11 27
    assert_contains "$RUN_OUTPUT" "Saved. With 19f5:2620 here the monitor shows input 17 on HDMI-A-1; without it, input 27."
    assert_eq "# From just monitor-input. dotfiles-monitor-input reads it.
device=19f5:2620
input=17
other=27
connector=HDMI-A-1" "$(cat "$MONITOR_INPUT_CONF")" "the settings"
    assert_file_contains "$MONITOR_INPUT_RULE" 'ACTION=="add|remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="19f5/2620/*", RUN+="/usr/bin/systemctl --no-block restart dotfiles-monitor-input.service"'
    assert_file_contains "$STUB_LOG" "udevadm control --reload"

    assert_exit 0 main 19f5:2620 17 27 HDMI-A-1
    assert_contains "$RUN_OUTPUT" "Already set."
    assert_file_not_contains "$STUB_LOG" "sudo"

    # Away from this machine the device isn't attached, which is fine
    rm -rf "$USB/1-2"
    assert_exit 0 main 046d:c548 17 27
    assert_contains "$RUN_OUTPUT" "046d:c548 isn't attached now"
    # The kernel's PRODUCT drops leading zeros
    assert_file_contains "$MONITOR_INPUT_RULE" 'ENV{PRODUCT}=="46d/c548/*"'
    usb_device 1-2 19f5:2620 "Air75 V3 Dongle"

    output card2-HDMI-A-2 connected 7
    assert_exit 1 main 19f5:2620 17 27
    assert_contains "$RUN_OUTPUT" "Name the connector the monitor is on, one of: HDMI-A-1, HDMI-A-2."
    rm -rf "$DRM/card2-HDMI-A-2"

    answer no
    assert_exit 0 main off
    [ -e "$MONITOR_INPUT_CONF" ] || fail "off removed the settings though confirm declined"
    answer yes
    assert_exit 0 main off
    [ ! -e "$MONITOR_INPUT_CONF" ] && [ ! -e "$MONITOR_INPUT_RULE" ] || fail "off left the settings"
}
subtest setup_on_ubuntu

setup_on_mac() {
    load_script monitor-input/setup.sh
    monitor_input_paths
    as_os macos
    stub ioreg 'cat <<"EOF"
+-o Root  <class IORegistryEntry, id 0x100000100, retain 25>
  +-o AppleT8132USBXHCI@01000000  <class AppleT8132USBXHCI>
    | +-o Air75 V3 Dongle@01120000  <class IOUSBHostDevice>
    |   {
    |     "idProduct" = 9760
    |     "USB Product Name" = "Air75 V3 Dongle"
    |     "idVendor" = 6645
    |   }
    | +-o Unnamed@01130000  <class IOUSBHostDevice>
    |   {
    |     "idVendor" = 1133
    |     "idProduct" = 50504
    |   }
EOF'

    hide m1ddc
    assert_exit 1 main 19f5:2620 27
    assert_contains "$RUN_OUTPUT" "m1ddc isn't installed"
    # Many lines, as a grep -q reading them would leave m1ddc writing to a closed pipe
    stub m1ddc '[ "$*" != "display list" ] || [ -e "$SANDBOX/no-display" ] || for i in $(seq 5000); do echo "[$i] DELL S2722QC (57670C1C)"; done'

    touch "$SANDBOX/no-display"
    assert_exit 1 main 19f5:2620 27
    assert_contains "$RUN_OUTPUT" "m1ddc finds no external display"
    rm "$SANDBOX/no-display"

    assert_exit 0 main 19f5:2620 0x1b
    assert_not_contains "$RUN_OUTPUT" "isn't attached now"
    assert_eq "# From just monitor-input. Hammerspoon reloads when this changes.
device=19f5:2620
input=27
m1ddc=$STUB_DIR/m1ddc" "$(cat "$MONITOR_INPUT_MAC_CONF")" "the Mac's settings"
    assert_file_not_contains "$STUB_LOG" "sudo"
    assert_file_not_contains "$STUB_LOG" "set input"
    assert_exit 0 main 19f5:2620 27
    assert_contains "$RUN_OUTPUT" "Already set."

    # The hammerspoon step reports switching only once it's on, and fails when m1ddc goes
    load_script hammerspoon/install.sh
    monitor_input_paths
    as_os macos
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "ok         Monitor input switching, with $STUB_DIR/m1ddc"
    sed -i.bak "s|^m1ddc=.*|m1ddc=$SANDBOX/gone/m1ddc|" "$MONITOR_INPUT_MAC_CONF"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Monitor input switching: m1ddc ($SANDBOX/gone/m1ddc) isn't installed"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "Copied"
    assert_contains "$RUN_OUTPUT" "Monitor input switching needs m1ddc"

    load_script monitor-input/setup.sh
    monitor_input_paths
    as_os macos
    assert_exit 0 main off
    [ ! -e "$MONITOR_INPUT_MAC_CONF" ] || fail "off left the Mac's settings"
    load_script hammerspoon/install.sh
    monitor_input_paths
    as_os macos
    assert_exit 0 main
    assert_exit 0 main --status
    assert_not_contains "$RUN_OUTPUT" "Monitor input"
}
subtest setup_on_mac

# Decimal codes are decimal even with a leading zero, which bash arithmetic would read as octal
input_codes() {
    load_script monitor-input/setup.sh
    assert_eq 17 "$(input_code 17)" "17"
    assert_eq 17 "$(input_code 017)" "017"
    assert_eq 8 "$(input_code 08)" "08"
    assert_eq 27 "$(input_code 0x1b)" "0x1b"
    assert_eq 27 "$(input_code 0X1B)" "0X1B"
    local code
    for code in 0 000 256 0x0 0x100 1b x1b 0x 1234 -1 ""; do
        ! input_code "$code" > /dev/null 2>&1 || fail "input_code accepted $code"
    done
}
subtest input_codes

# The switcher takes its paths from the environment, which the service doesn't set.
switcher() {
    assert_exit "$1" env MONITOR_INPUT_CONF="$SANDBOX/switcher.conf" USB_DEVICES_DIR="$USB" DRM_DIR="$DRM" \
        MONITOR_INPUT_SETTLE=0 MONITOR_INPUT_VERIFY_DELAY=0 "$BASH" "$REPO_DIR/monitor-input/dotfiles-monitor-input"
}

# A monitor that shows the last input set, except that it ignores as many sets as the drops file
# holds. With the mute file, it answers reads only while it shows this machine's input, 17.
stub_monitor() {
    echo 27 > "$SANDBOX/monitor-shows"
    echo 0 > "$SANDBOX/monitor-drops"
    rm -f "$SANDBOX/monitor-mute"
    stub ddcutil 'shows="$SANDBOX/monitor-shows" drops="$SANDBOX/monitor-drops"
case "$*" in
    *getvcp\ 60*)
        if [ -e "$SANDBOX/monitor-mute" ] && [ "$(cat "$shows")" != 17 ]; then
            echo "DDC communication failed" >&2
            exit 1
        fi
        printf "VCP 60 SNC x%02x\n" "$(cat "$shows")"
        ;;
    *setvcp\ 60*)
        if [ "$(cat "$drops")" -gt 0 ]; then
            echo $(($(cat "$drops") - 1)) > "$drops"
        else
            echo "${*: -1}" > "$shows"
        fi
        ;;
esac'
}

the_switcher() {
    output card1-HDMI-A-1 connected 4
    stub_monitor
    switcher 0
    assert_file_not_contains "$STUB_LOG" "ddcutil"

    printf '%s\n' device=19f5:2620 input=17 connector=HDMI-A-1 > "$SANDBOX/switcher.conf"
    switcher 1
    assert_contains "$RUN_OUTPUT" "needs device, input, other, and connector"
    assert_file_not_contains "$STUB_LOG" "ddcutil"

    printf '%s\n' "# a comment" device=19f5:2620 input=17 other=27 connector=HDMI-A-1 > "$SANDBOX/switcher.conf"
    switcher 0
    assert_eq "ddcutil --bus 4 --noverify setvcp 60 17
ddcutil --bus 4 getvcp 60 --brief" "$(cat "$STUB_LOG")" "ddcutil with the device here"
    assert_eq 17 "$(cat "$SANDBOX/monitor-shows")" "the input with the device here"

    # The bus comes from the connector each run, since it can change across boots
    rm -rf "$USB/1-2"
    output card1-HDMI-A-1 connected 9
    switcher 0
    assert_eq "ddcutil --bus 9 --noverify setvcp 60 27
ddcutil --bus 9 getvcp 60 --brief" "$(cat "$STUB_LOG")" "ddcutil with the device away"
    assert_eq 27 "$(cat "$SANDBOX/monitor-shows")" "the input with the device away"

    # A command the monitor misses is sent again
    usb_device 1-2 19f5:2620 "Air75 V3 Dongle"
    echo 2 > "$SANDBOX/monitor-drops"
    switcher 0
    assert_contains "$RUN_OUTPUT" "The monitor shows input 27; trying again (3 of 5)."
    assert_eq 3 "$(grep -c "setvcp 60 17" "$STUB_LOG")" "sets with two missed"
    assert_eq 17 "$(cat "$SANDBOX/monitor-shows")" "the input after two missed sets"

    echo 27 > "$SANDBOX/monitor-shows"
    echo 9 > "$SANDBOX/monitor-drops"
    switcher 1
    assert_contains "$RUN_OUTPUT" "The monitor didn't switch to input 17 after 5 tries."
    assert_eq 5 "$(grep -c "setvcp 60 17" "$STUB_LOG")" "sets with every one missed"

    # A monitor that stops answering once it shows the other machine has switched away
    touch "$SANDBOX/monitor-mute"
    echo 17 > "$SANDBOX/monitor-shows"
    echo 0 > "$SANDBOX/monitor-drops"
    rm -rf "$USB/1-2"
    switcher 0
    assert_contains "$RUN_OUTPUT" "taking it as switched"
    assert_eq 1 "$(grep -c "setvcp 60 27" "$STUB_LOG")" "sets away from a monitor that stops answering"
    assert_eq 27 "$(cat "$SANDBOX/monitor-shows")" "the input away from a monitor that stops answering"

    # Switching here, though, an unreadable input means the monitor missed the command
    usb_device 1-2 19f5:2620 "Air75 V3 Dongle"
    echo 1 > "$SANDBOX/monitor-drops"
    switcher 0
    assert_contains "$RUN_OUTPUT" "The monitor shows input (unreadable); trying again (2 of 5)."
    assert_not_contains "$RUN_OUTPUT" "taking it as switched"
    assert_eq 2 "$(grep -c "setvcp 60 17" "$STUB_LOG")" "sets here with one missed on a monitor that stops answering"
    assert_eq 17 "$(cat "$SANDBOX/monitor-shows")" "the input here on a monitor that stops answering"
    rm "$SANDBOX/monitor-mute"

    rm "$DRM/card1-HDMI-A-1/ddc"
    switcher 1
    assert_contains "$RUN_OUTPUT" "No DDC bus for the HDMI-A-1 connector"
    assert_file_not_contains "$STUB_LOG" "ddcutil"

    # A failed set is retried too
    output card1-HDMI-A-1 connected 4
    stub ddcutil 'exit 1'
    switcher 1
    assert_contains "$RUN_OUTPUT" "The monitor shows input (unreadable); trying again (2 of 5)."
    assert_eq 5 "$(grep -c "setvcp 60 17" "$STUB_LOG")" "sets when ddcutil fails"
}
subtest the_switcher

test_done
