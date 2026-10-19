#!/bin/bash
set -euo pipefail

# Copy the Zed settings and keymap.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Zed on macOS ignores XDG_CONFIG_HOME
if is_macos; then
    ZED_DIR="$HOME/.config/zed"
else
    ZED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zed"
fi

# Replaced whole, not merged: a jq merge would strip JSONC comments
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
