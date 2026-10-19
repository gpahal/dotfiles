#!/bin/bash
set -euo pipefail

# Copy the Zed settings and keymap.
#
# A run replaces copies edited in the app or by hand, so `just copy-back` copies those changes back
# to the repo first. The homebrew step installs Zed on both OSes.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Zed reads ~/.config/zed on macOS even when XDG_CONFIG_HOME is set, and $XDG_CONFIG_HOME/zed on
# Ubuntu
if is_macos; then
    ZED_DIR="$HOME/.config/zed"
else
    ZED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zed"
fi

# The files are JSONC, whose comments a jq merge would strip, so they're replaced whole, unlike
# other apps' settings
zed_files() {
    local file status=0
    for file in settings.json keymap.json; do
        "$1" "$DOTFILES_DIR/zed/$file" "$ZED_DIR/$file" || status=1
    done
    return "$status"
}

status() {
    zed_files status_file
    status_result
}

apply() {
    echo "Copying Zed config..."
    zed_files copy_file
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
