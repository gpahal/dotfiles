#!/bin/bash
set -euo pipefail

# Copy the Zed settings and keymap.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ZED_DIR="$(app_config_dir zed)"

# Replaced whole, not merged: a jq merge would strip JSONC comments
zed_files() {
    local file status=0
    for file in settings.json keymap.json; do
        "$1" "$DOTFILES_DIR/zed/$file" "$ZED_DIR/$file" || status=1
    done
    return "$status"
}

status() {
    copy_status zed_files
}

apply() {
    copy_step "Copying Zed config..." zed_files
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
