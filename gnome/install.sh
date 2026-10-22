#!/bin/bash
set -euo pipefail

# Match GNOME's keyboard, Files, and dock to the macos step, and add Quick Look.
# gsettings writes your session's GNOME settings whatever HOME is; run it under dbus-run-session
# with a temp HOME and XDG_RUNTIME_DIR to test it. gnome-sushi installs with sudo.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

STEP_OS=ubuntu

# <schema>|<key>|<value as gsettings prints it>|<what it does>. The value is GVariant text, which
# gsettings set also takes.
GNOME_SETTINGS=(
    # The macos step's InitialKeyRepeat 15 and KeyRepeat 2, in 15 ms units
    "org.gnome.desktop.peripherals.keyboard|delay|uint32 225|Keys repeat after 225 ms"
    "org.gnome.desktop.peripherals.keyboard|repeat-interval|uint32 30|Keys repeat every 30 ms"
    # Files and GTK 4 file choosers read the gtk4 key, GTK 3 file choosers the other. Both, as
    # AppleShowAllFiles covers Finder and file dialogs.
    "org.gtk.Settings.FileChooser|show-hidden|true|GTK 3 file choosers show hidden files"
    "org.gtk.gtk4.Settings.FileChooser|show-hidden|true|Files and GTK 4 file choosers show hidden files"
    "org.gnome.nautilus.preferences|default-folder-viewer|'list-view'|Files opens folders in list view"
    # With dock-fixed and intellihide off, the dock stays hidden until the pointer reaches the edge,
    # as on the Mac
    "org.gnome.shell.extensions.dash-to-dock|dock-fixed|false|Dock not pinned open"
    "org.gnome.shell.extensions.dash-to-dock|autohide|true|Dock hides"
    "org.gnome.shell.extensions.dash-to-dock|intellihide|false|Dock hides even with no window under it"
)

setting_value() {
    gsettings get "$1" "$2" 2> /dev/null
}

# 0: set; 1: differs; 2: no such schema or key, as with the dock on GNOME without Ubuntu's
setting_state() {
    local current
    current="$(setting_value "$1" "$2")" || return 2
    [ "$current" == "$3" ]
}

sushi_installed() {
    apt_installed gnome-sushi
}

install_sushi() {
    apt_get_update && apt_get install -y gnome-sushi
}

gnome_items() {
    items_reset
    item --sudo "Quick Look: gnome-sushi, so Space in Files previews the selected file" \
        "Install gnome-sushi, so Space in Files previews the selected file" sushi_installed install_sushi
}

status() {
    local setting schema key value text state
    if ! has_gnome_desktop; then
        status_item skipped "GNOME settings: no GNOME desktop"
        return 0
    fi
    status_require_cmd gsettings "GNOME settings" || { status_result; return; }
    for setting in "${GNOME_SETTINGS[@]}"; do
        IFS='|' read -r schema key value text <<< "$setting"
        state=0
        setting_state "$schema" "$key" "$value" || state=$?
        case "$state" in
            0) status_item ok "$text ($schema $key)" ;;
            1) status_item missing "$text ($schema $key is $(setting_value "$schema" "$key"), not $value)" ;;
            *) status_item skipped "$text: GNOME has no $schema $key here" ;;
        esac
    done
    gnome_items
    items_status
    status_result
}

apply() {
    echo "Setting GNOME's keyboard, Files, and dock..."
    if ! has_gnome_desktop; then
        echo "  No GNOME desktop, so skipped."
        return 0
    fi
    require_cmd gsettings || return 1
    local setting schema key value text state result=0 changed=false pending=()
    for setting in "${GNOME_SETTINGS[@]}"; do
        IFS='|' read -r schema key value text <<< "$setting"
        state=0
        setting_state "$schema" "$key" "$value" || state=$?
        case "$state" in
            0) continue ;;
            2)
                echo "  GNOME has no $schema $key here, so skipped: $text."
                continue
                ;;
        esac
        if gsettings set "$schema" "$key" "$value"; then
            echo "  $text ($schema $key = $value)"
            changed=true
        else
            echo "  Couldn't set $schema $key to $value." >&2
            result=1
        fi
    done
    "$changed" || [ "$result" -ne 0 ] || echo "  The settings are already set."

    gnome_items
    items_pending
    if [ ${#pending[@]} -gt 0 ] && confirm_sudo_changes "${pending[@]}"; then
        items_apply || result=1
        [ "$result" -ne 0 ] || echo "  Applied."
    fi
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
