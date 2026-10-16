#!/bin/bash
set -euo pipefail

# Copy the Hammerspoon config, whose hotkeys open Claude and Chrome and a new Chrome tab with the
# clipboard pasted. A running Hammerspoon reloads it when it changes, and the config sets
# Hammerspoon to open at login. macOS only, since Hammerspoon has no Linux app. The homebrew step
# installs Hammerspoon.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Pass the file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
hammerspoon_files() {
    is_macos || return 0
    "$1" "$DOTFILES_DIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"
}

status() {
    if ! is_macos; then
        status_item skipped "Hammerspoon config: Hammerspoon has no Linux app"
        return 0
    fi
    hammerspoon_files status_file
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Copying Hammerspoon config..."
    if ! is_macos; then
        echo "  Hammerspoon has no Linux app; skipping."
        return 0
    fi
    hammerspoon_files copy_file
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
