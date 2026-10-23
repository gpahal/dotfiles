#!/bin/bash
set -euo pipefail

# Save this machine's monitor inputs and the USB device that marks where the USB switch points.
# Run it on each machine; with no arguments it lists the USB devices and the input codes.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"
# shellcheck source=lib/paths.sh
source "$DOTFILES_DIR/monitor-input/lib/paths.sh"

usage() {
    echo "Usage: bash monitor-input/setup.sh [<vendor:product> <input> [<mac-input> [<connector>]] | off]"
    echo "  (or: just monitor-input ...)"
    echo "Points the monitor at whichever machine the USB switch serves. Pick a device the switch"
    echo "moves, such as the keyboard's receiver, and the monitor input each machine is plugged into."
    echo "  On the Mac:    <vendor:product> <the Mac's input>"
    echo "  On Ubuntu:     <vendor:product> <this machine's input> <the Mac's input> [<connector>]"
    echo "The Mac switches the monitor to itself when it gets the device. Ubuntu does the same, and"
    echo "switches it to the Mac when the device leaves, so it still follows while the Mac sleeps."
    echo "<connector> is the video output the monitor is on, such as HDMI-A-1; the default is the"
    echo "only connected one. With no arguments, lists the USB devices and the common input codes."
    echo "off turns switching off on this machine."
}

INPUT_CODES="Common input codes (DDC/CI VCP 0x60): 15 DisplayPort 1, 16 DisplayPort 2, 17 HDMI 1,
18 HDMI 2, 27 USB-C (Dell). Check one by switching to it and back:
  Mac:    m1ddc set input <code>
  Ubuntu: ddcutil --bus <n> setvcp 60 <code>   (ddcutil detect shows <n>)"

# "<vendor:product> <name>" for each attached USB device
usb_devices() {
    local dir
    if is_macos; then
        # Each device's properties follow its "+-o" line
        ioreg -p IOUSB -l -w0 | awk -F' = ' '
            function flush() { if (v != "") printf "%04x:%04x %s\n", v, p, n; v = ""; p = ""; n = "" }
            /\+-o / { flush(); n = $0; sub(/.*\+-o /, "", n); sub(/@.*/, "", n) }
            /"idVendor" = / { v = $2 + 0 }
            /"idProduct" = / { p = $2 + 0 }
            /"USB Product Name" = / { n = $2; gsub(/"/, "", n) }
            END { flush() }'
    else
        for dir in "$USB_DEVICES_DIR"/*; do
            [ -r "$dir/idVendor" ] && [ -r "$dir/idProduct" ] || continue
            echo "$(cat "$dir/idVendor"):$(cat "$dir/idProduct") $(cat "$dir/product" 2>/dev/null || true)"
        done
    fi | sort -u
}

# Not usb_devices | grep -q: grep exits at the first match, and under pipefail the writer's SIGPIPE
# fails the pipeline
device_attached() {
    local devices
    devices="$(usb_devices)"
    grep -q "^$1 " <<< "$devices"
}

# Connected outputs with a DDC channel, without the card prefix: HDMI-A-1
ddc_connectors() {
    local dir name
    for dir in "$DRM_DIR"/card*-*; do
        [ -e "$dir/ddc" ] && [ "$(cat "$dir/status" 2>/dev/null)" == connected ] || continue
        name="${dir##*/}"
        echo "${name#card*-}"
    done
}

list() {
    usage
    echo
    echo "USB devices attached now:"
    usb_devices | sed 's/^/  /'
    if is_ubuntu; then
        echo
        echo "Connected video outputs with DDC: $(ddc_connectors | join_lines ', ')"
    fi
    echo
    echo "$INPUT_CODES"
}

# Prints the code in decimal; accepts 0x hex. 10# reads 017 as 17, not octal.
input_code() {
    local code
    if [[ "$1" =~ ^0[xX][0-9a-fA-F]{1,2}$ ]]; then
        code=$(($1))
    elif [[ "$1" =~ ^[0-9]{1,3}$ ]]; then
        code=$((10#$1))
    else
        return 1
    fi
    [ "$code" -ge 1 ] && [ "$code" -le 255 ] || return 1
    echo "$code"
}

rule_content() {
    local vendor="${1%%:*}" product="${1##*:}"
    echo "# From just monitor-input: re-check the monitor's input when the USB switch moves $1"
    printf '%s\n' "ACTION==\"add|remove\", SUBSYSTEM==\"usb\", ENV{DEVTYPE}==\"usb_device\", ENV{PRODUCT}==\"$(printf '%x/%x' "0x$vendor" "0x$product")/*\", RUN+=\"/usr/bin/systemctl --no-block restart dotfiles-monitor-input.service\""
}

setup_mac() {
    local device="$1" input="$2" m1ddc content
    if [ $# -gt 2 ]; then
        echo "The Mac only switches the monitor to itself, so give only its own input." >&2
        return 2
    fi
    require_cmd m1ddc || return 1
    m1ddc="$(command -v m1ddc)"
    if [ -z "$(m1ddc display list 2>/dev/null)" ]; then
        echo "m1ddc finds no external display. Connect the monitor and re-run." >&2
        return 1
    fi
    content="# From just monitor-input. Hammerspoon reloads when this changes.
device=$device
input=$input
m1ddc=$m1ddc"
    echo "Monitor input switching ($MONITOR_INPUT_MAC_CONF):"
    if file_is "$MONITOR_INPUT_MAC_CONF" "$content"; then
        echo "  Already set."
        return 0
    fi
    mkdir -p "$(dirname "$MONITOR_INPUT_MAC_CONF")"
    printf '%s\n' "$content" > "$MONITOR_INPUT_MAC_CONF"
    echo "  Saved. When the Mac gets $device, Hammerspoon switches the monitor to input $input."
}

setup_ubuntu() {
    local device="$1" input="$2" other="${3:-}" connector="${4:-}" connectors content rule
    if [ -z "$other" ]; then
        echo "Give the Mac's input too, so this machine can hand the monitor back while the Mac sleeps." >&2
        return 2
    fi
    if ! other="$(input_code "$other")"; then
        echo "The Mac's input should be a code from 1 to 255, such as 27 or 0x1b." >&2
        return 2
    fi
    if [ "$other" == "$input" ]; then
        echo "This machine's input and the Mac's are both $input." >&2
        return 2
    fi
    if [ -z "$connector" ]; then
        connectors="$(ddc_connectors)"
        if [ -z "$connectors" ] || [ "$(wc -l <<< "$connectors")" -ne 1 ]; then
            echo "Name the connector the monitor is on, one of: $(join_lines ', ' <<< "${connectors:-(none connected)}")." >&2
            return 1
        fi
        connector="$connectors"
    elif ! grep -qxF "$connector" <<< "$(ddc_connectors)"; then
        echo "$connector isn't a connected output with DDC. Connected: $(ddc_connectors | join_lines ', ')." >&2
        return 1
    fi
    [ -x "$MONITOR_INPUT_SCRIPT" ] || echo "The input switcher isn't installed yet; bash setup.sh monitor-input installs it."
    content="# From just monitor-input. dotfiles-monitor-input reads it.
device=$device
input=$input
other=$other
connector=$connector"
    rule="$(rule_content "$device")"
    echo "Monitor input switching ($MONITOR_INPUT_CONF, $MONITOR_INPUT_RULE):"
    if file_is "$MONITOR_INPUT_CONF" "$content" && file_is "$MONITOR_INPUT_RULE" "$rule"; then
        echo "  Already set."
        return 0
    fi
    if ! confirm "  Save them with sudo?"; then
        left_unchanged "  " "this script" "save them"
        return 0
    fi
    if ! write_root_file "$MONITOR_INPUT_CONF" "$content" 0644 || ! write_root_file "$MONITOR_INPUT_RULE" "$rule" 0644 ||
        ! sudo udevadm control --reload; then
        echo "  Couldn't save them." >&2
        return 1
    fi
    echo "  Saved. With $device here the monitor shows input $input on $connector; without it, input $other."
}

turn_off() {
    if is_macos; then
        rm -f "$MONITOR_INPUT_MAC_CONF"
    elif [ -e "$MONITOR_INPUT_CONF" ] || [ -e "$MONITOR_INPUT_RULE" ]; then
        if ! confirm "Remove $MONITOR_INPUT_CONF and $MONITOR_INPUT_RULE with sudo?"; then
            echo "Left unchanged."
            return 0
        fi
        sudo rm -f "$MONITOR_INPUT_CONF" "$MONITOR_INPUT_RULE" || return 1
        sudo udevadm control --reload || return 1
    fi
    echo "Monitor input switching is off on this machine."
}

main() {
    local device input
    case "${1:-}" in
        -h | --help)
            usage
            return 0
            ;;
        "")
            list
            return 0
            ;;
        off)
            turn_off
            return
            ;;
    esac
    if [ $# -lt 2 ] || [ $# -gt 4 ]; then
        usage >&2
        return 2
    fi
    device="$(tr '[:upper:]' '[:lower:]' <<< "$1")"
    if ! [[ "$device" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]]; then
        echo "$1 isn't a USB vendor:product ID, such as 046d:c548. Run this with no arguments to list them." >&2
        return 2
    fi
    if ! input="$(input_code "$2")"; then
        echo "The input should be a code from 1 to 255, such as 17 or 0x11." >&2
        return 2
    fi
    device_attached "$device" || echo "Note: $device isn't attached now. That's expected if the switch serves the other machine."
    shift 2
    if is_macos; then
        setup_mac "$device" "$input" "$@"
    elif is_ubuntu; then
        setup_ubuntu "$device" "$input" "$@"
    else
        echo "Only macOS and Ubuntu are supported." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
