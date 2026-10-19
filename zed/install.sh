#!/bin/bash
set -euo pipefail

# Copy the Zed settings and keymap. Ask before replacing copies edited in the app or by hand;
# copy those changes back to the repo (see README Maintenance). The homebrew step installs Zed
# on both OSes.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Zed reads ~/.config/zed on macOS even when XDG_CONFIG_HOME is set, and $XDG_CONFIG_HOME/zed on
# Ubuntu
if is_macos; then
    ZED_DIR="$HOME/.config/zed"
else
    ZED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zed"
fi

# Pass each file the step copies, as source and destination, to a function, followed by any
# further arguments: copy_file_ask to copy it, or status_file to report it. The files are JSONC,
# whose comments a jq merge would strip, so they're replaced whole, unlike other apps' settings.
zed_files() {
    local action="$1" file status=0
    shift
    for file in settings.json keymap.json; do
        "$action" "$DOTFILES_DIR/zed/$file" "$ZED_DIR/$file" "$@" || status=1
    done
    return "$status"
}

status() {
    zed_files status_file "merge by hand"
    status_result
}

apply() {
    echo "Copying Zed config..."
    zed_files copy_file_ask
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
