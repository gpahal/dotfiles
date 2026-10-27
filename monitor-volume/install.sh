#!/bin/bash
set -euo pipefail

# Install ddcutil and a service that makes the volume keys set the monitor's own volume.
# While the monitor is the sound output, the service hands the volume up and down keys from GNOME
# to dotfiles-monitor-volume, and hands them back when it isn't. ddcutil installs with sudo, and
# the service changes your session's GNOME shortcuts whatever HOME is: test it in an Ubuntu VM
# with GNOME. The Mac's half is in hammerspoon/init.lua.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/gnome.sh
source "$DOTFILES_DIR/lib/gnome.sh"
# shellcheck source=../lib/systemd.sh
source "$DOTFILES_DIR/lib/systemd.sh"

STEP_OS=ubuntu

VOLUME_SRC="$DOTFILES_DIR/monitor-volume/dotfiles-monitor-volume"
VOLUME_SCRIPT="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/monitor-volume/dotfiles-monitor-volume"
VOLUME_UNIT_NAME=dotfiles-monitor-volume.service
VOLUME_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$VOLUME_UNIT_NAME"
# Kept from a change to the script or unit until the service restarts on it
VOLUME_RESTART_PENDING="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/monitor-volume-restart-pending"

monitor_volume_files() {
    "$1" "$VOLUME_SRC" "$VOLUME_SCRIPT"
}

volume_unit() {
    local script
    script="$(systemd_quote "$VOLUME_SCRIPT")"
    printf '%s\n' "# From the dotfiles monitor-volume step: the volume keys set the monitor's volume" \
        "[Unit]" "Description=Hand the volume keys to the monitor while it's the sound output" \
        "PartOf=graphical-session.target" "After=graphical-session.target wireplumber.service" "" \
        "[Service]" "ExecStart=$script watch" "ExecStopPost=$script release" \
        "Restart=on-failure" "RestartSec=5" "" \
        "[Install]" "WantedBy=graphical-session.target"
}

monitor_volume_items() {
    items_reset
    item --sudo "ddcutil" "Install ddcutil, which sets the monitor's volume over DDC/CI" \
        "apt_installed ddcutil" "apt_install_fresh ddcutil"
}

# A slow check: ddcutil takes about a second to find the monitor
status_ddc() {
    if status_for_alerts || ! command -v ddcutil &> /dev/null; then
        return 0
    elif ddcutil getvcp 62 --brief &> /dev/null; then
        status_item ok "The monitor answers volume over DDC/CI"
    else
        status_item unverified "The monitor answers volume over DDC/CI: it doesn't now; it answers only while it shows this machine, with DDC/CI on in its menu"
    fi
}

status() {
    skip_without_desktop --status "Monitor volume keys" && return 0
    status_require_cmd gsettings "Monitor volume keys" || return 0
    status_require_cmd wpctl "Monitor volume keys" || return 0
    monitor_volume_items
    items_status
    monitor_volume_files status_file
    status_check "Monitor volume service ($(shown_path "$VOLUME_UNIT"))" file_is "$VOLUME_UNIT" "$(volume_unit)"
    [ ! -e "$VOLUME_RESTART_PENDING" ] ||
        status_item missing "Monitor volume service restarted on its new files: re-run the monitor-volume step"
    [ ! -f "$VOLUME_UNIT" ] || status_user_service "$VOLUME_UNIT_NAME" "Monitor volume service"
    status_ddc
}

mark_restart_pending() {
    mkdir -p "$(dirname "$VOLUME_RESTART_PENDING")" && touch "$VOLUME_RESTART_PENDING"
}

# Restarts the service when its script or unit changed, so it runs the new ones. The pending mark
# outlasts a failed run, so the next one still restarts it.
setup_service() {
    local changed=false
    COPIED=false
    monitor_volume_files copy_file || return 1
    ! "$COPIED" || mark_restart_pending || return 1
    if ! file_is "$VOLUME_UNIT" "$(volume_unit)"; then
        mkdir -p "$(dirname "$VOLUME_UNIT")" && mark_restart_pending &&
            write_content "$VOLUME_UNIT" "$(volume_unit)" || return 1
        echo "  Wrote $(shown_path "$VOLUME_UNIT")"
    fi
    [ ! -e "$VOLUME_RESTART_PENDING" ] || changed=true
    user_manager_reachable "the monitor volume service isn't on" || return 0
    start_user_service "$VOLUME_UNIT_NAME" "the monitor volume service" "$changed" || return 1
    rm -f "$VOLUME_RESTART_PENDING"
}

apply() {
    echo "Setting up the monitor volume keys..."
    skip_without_desktop && return 0
    require_cmd gsettings || return 1
    # From pipewire-bin, which Ubuntu's desktop installs
    require_cmd wpctl || return 1
    require_cmd pw-metadata || return 1
    local result=0
    monitor_volume_items
    items_apply_confirmed --done "  ddcutil is already installed." || result=1
    setup_service || result=1
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
