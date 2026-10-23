#!/bin/bash
set -euo pipefail

# Install ddcutil and a service that switches the monitor to follow the USB switch.
# Changes the system with sudo whatever HOME is: test it in an Ubuntu VM with systemd.
# The Mac's half is in hammerspoon/init.lua. just monitor-input sets each machine's inputs.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=lib/paths.sh
source "$DOTFILES_DIR/monitor-input/lib/paths.sh"

STEP_OS=ubuntu

SCRIPT_SRC="$DOTFILES_DIR/monitor-input/dotfiles-monitor-input"
UNIT_SRC="$DOTFILES_DIR/monitor-input/dotfiles-monitor-input.service"

script_installed() {
    cmp -s "$SCRIPT_SRC" "$MONITOR_INPUT_SCRIPT" && [ -x "$MONITOR_INPUT_SCRIPT" ]
}

install_script() {
    install_root_file "$SCRIPT_SRC" "$MONITOR_INPUT_SCRIPT" 0755
}

unit_installed() {
    cmp -s "$UNIT_SRC" "$MONITOR_INPUT_UNIT"
}

install_unit() {
    install_root_file "$UNIT_SRC" "$MONITOR_INPUT_UNIT" 0644 && sudo systemctl daemon-reload
}

monitor_input_items() {
    items_reset
    item --sudo "ddcutil" "Install ddcutil, which sets the monitor's input over DDC/CI" \
        "apt_installed ddcutil" "apt_install_fresh ddcutil"
    item --sudo "Input switcher ($MONITOR_INPUT_SCRIPT)" "Install $MONITOR_INPUT_SCRIPT" \
        script_installed install_script
    item --sudo "Input switcher's service ($MONITOR_INPUT_UNIT)" "Install $MONITOR_INPUT_UNIT" \
        unit_installed install_unit
}

conf_get() {
    sed -n "s/^$1=//p" "$MONITOR_INPUT_CONF" 2>/dev/null | tail -n 1
}

connector_has_ddc() {
    local link
    for link in "$DRM_DIR"/card*-"$1"/ddc; do
        [ -e "$link" ] && return 0
    done
    return 1
}

# This machine's settings, which just monitor-input writes
status_settings() {
    local connector
    if [ ! -e "$MONITOR_INPUT_CONF" ]; then
        status_item info "Monitor input switching is off; just monitor-input turns it on"
        return 0
    fi
    if [ ! -e "$MONITOR_INPUT_RULE" ]; then
        status_item missing "Monitor input switching: $MONITOR_INPUT_RULE is missing; re-run just monitor-input"
        return 0
    fi
    connector="$(conf_get connector)"
    if [ -z "$connector" ] || ! connector_has_ddc "$connector"; then
        status_item missing "Monitor input switching: the ${connector:-(unset)} connector has no DDC bus; check the cable, or re-run just monitor-input"
        return 0
    fi
    status_item ok "Monitor input switching on $connector, for USB device $(conf_get device)"
}

status() {
    monitor_input_items
    items_status
    status_settings
}

apply() {
    echo "Setting up monitor input switching..."
    local pending=()
    monitor_input_items
    items_pending
    if [ ${#pending[@]} -eq 0 ]; then
        echo "  ddcutil and the input switcher are already installed."
    else
        confirm_sudo_changes "${pending[@]}" || return 0
        items_apply || return 1
        echo "  Applied."
    fi
    [ -e "$MONITOR_INPUT_CONF" ] || echo "  Switching stays off until just monitor-input sets this machine's inputs."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
