#!/bin/bash
set -euo pipefail

# Copy the Hammerspoon config, whose hotkeys open Claude, Chrome, a new Chrome tab with the
# clipboard pasted, Ghostty and Zed at the folder or file in front, and T3 Code, and the Stream
# Deck plugin's bin/open-in, which finds the folder or file and opens the new tab. A running
# Hammerspoon reloads the config when it changes, and the config sets Hammerspoon to open at login.
# macOS only, since Hammerspoon has no Linux app. The homebrew step installs Hammerspoon.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

STEP_OS=macos

# Pass each file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
hammerspoon_files() {
    local status=0
    "$1" "$DOTFILES_DIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua" || status=1
    "$1" "$DOTFILES_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in" \
        "$HOME/.hammerspoon/bin/open-in" || status=1
    return "$status"
}

status() { copy_status hammerspoon_files; }

apply() { copy_step "Copying Hammerspoon config..." hammerspoon_files; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
