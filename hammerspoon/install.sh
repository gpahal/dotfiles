#!/bin/bash
set -euo pipefail

# Copy the Hammerspoon config and the open-in script its hotkeys run.
# Its monitor input switching needs m1ddc only once just monitor-input turns it on.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck source=../monitor-input/lib/paths.sh
source "$DOTFILES_DIR/monitor-input/lib/paths.sh"

STEP_OS=macos

hammerspoon_files() {
    local status=0
    "$1" "$DOTFILES_DIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua" || status=1
    "$1" "$DOTFILES_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in" \
        "$HOME/.hammerspoon/bin/open-in" || status=1
    return "$status"
}

monitor_m1ddc() {
    sed -n 's/^m1ddc=//p' "$MONITOR_INPUT_MAC_CONF" 2>/dev/null | tail -n 1
}

monitor_m1ddc_missing() {
    local m1ddc
    [ -e "$MONITOR_INPUT_MAC_CONF" ] || return 1
    m1ddc="$(monitor_m1ddc)"
    [ -z "$m1ddc" ] || [ ! -x "$m1ddc" ]
}

status() {
    hammerspoon_files status_file
    # Off until just monitor-input turns it on
    if monitor_m1ddc_missing; then
        status_item missing "Monitor input switching: m1ddc ($(monitor_m1ddc)) isn't installed; run bash setup.sh homebrew, then just monitor-input"
    elif [ -e "$MONITOR_INPUT_MAC_CONF" ]; then
        status_item ok "Monitor input switching, with $(monitor_m1ddc)"
    fi
}

apply() {
    copy_step "Copying Hammerspoon config..." hammerspoon_files || return 1
    if monitor_m1ddc_missing; then
        echo "  Monitor input switching needs m1ddc ($(monitor_m1ddc)). Run bash setup.sh homebrew, then just monitor-input." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
