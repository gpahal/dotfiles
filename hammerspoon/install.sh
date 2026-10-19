#!/bin/bash
set -euo pipefail

# Copy the Hammerspoon config and the open-in script its hotkeys run.
#
# init.lua lists the hotkeys. macOS only, since Hammerspoon has no Linux app.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

STEP_OS=macos

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
