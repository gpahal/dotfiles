#!/bin/bash
set -euo pipefail

# Add GNOME shortcuts on Ctrl+Alt+Super that match Hammerspoon's.
# They run the Stream Deck's open-in, from the stream-deck step.
# gsettings writes your session's GNOME settings whatever HOME is; run it under dbus-run-session
# with a temp HOME and XDG_RUNTIME_DIR to test it.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/gnome.sh
source "$DOTFILES_DIR/lib/gnome.sh"

STEP_OS=ubuntu
# The shortcuts run its open-in, which needs its GNOME extension
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="stream-deck"

OPEN_IN="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/stream-deck/bin/open-in"
# <key> <open-in target> <name>, as in hammerspoon/init.lua
HOTKEYS=(
    "space claude Claude"
    "b chrome Chrome"
    "c t3-code T3_Code"
    "t terminal Terminal"
    "e editor Editor"
    "n chrome-tab New_Tab"
    "a agenda Agenda"
    "m gmail Gmail"
)

# As README's Hammerspoon section writes them: Space, B
key_label() {
    if [ "$1" == space ]; then echo Space; else echo "$1" | tr '[:lower:]' '[:upper:]'; fi
}

hotkey_path() {
    echo "$GNOME_KEYBINDING_DIR/dotfiles-$1/"
}

# The command field is split like a shell's; systemd-cat sends open-in's log to the journal
hotkey_command() {
    printf "systemd-cat -t dotfiles-hotkeys env OPEN_IN_CALLER=Hotkeys 'OPEN_IN_LOG=journalctl --user -t dotfiles-hotkeys' /bin/bash '%s' %s" \
        "$OPEN_IN" "$1"
}

# hotkey <status|apply>_gnome_keybinding <key> <target> <name>
hotkey() {
    local key="$2" target="$3"
    "$1" "Ctrl+Alt+Super+$(key_label "$key")" "$(hotkey_path "$target")" "${4//_/ }" \
        "$(hotkey_command "$target")" "<Control><Alt><Super>$key"
}

status() {
    local hotkey key target name
    skip_without_desktop --status "GNOME shortcuts" && return 0
    status_require_cmd gsettings "GNOME shortcuts" || return 0
    if [ ! -x "$OPEN_IN" ]; then
        status_item missing "The Stream Deck's open-in, which the shortcuts run: bash setup.sh stream-deck"
    fi
    for hotkey in "${HOTKEYS[@]}"; do
        read -r key target name <<< "$hotkey"
        hotkey status_gnome_keybinding "$key" "$target" "$name"
    done
}

apply() {
    echo "Adding GNOME shortcuts..."
    skip_without_desktop && return 0
    require_cmd gsettings || return 1
    if [ ! -x "$OPEN_IN" ]; then
        echo "  The shortcuts run the Stream Deck's open-in, which isn't installed. Run: bash setup.sh stream-deck" >&2
        return 1
    fi
    local hotkey key target name status=0 GNOME_KEYBINDING_CHANGED=false
    for hotkey in "${HOTKEYS[@]}"; do
        read -r key target name <<< "$hotkey"
        hotkey apply_gnome_keybinding "$key" "$target" "$name" || status=1
    done
    "$GNOME_KEYBINDING_CHANGED" || [ "$status" -ne 0 ] || echo "  The shortcuts are already set."
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
