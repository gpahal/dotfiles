#!/bin/bash
set -euo pipefail

# Copy the Zed settings and keymap. Zed edits settings.json itself when you change a setting
# in the app, so copy those changes back to the repo before re-running (see the README's
# Maintenance section).

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
    echo "Copying Zed config..."
    copy_file "$DOTFILES_DIR/zed/settings.json" "$HOME/.config/zed/settings.json"
    copy_file "$DOTFILES_DIR/zed/keymap.json" "$HOME/.config/zed/keymap.json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
