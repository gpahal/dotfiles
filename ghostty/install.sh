#!/bin/bash
set -euo pipefail

# Copy the Ghostty config and reload it in running Ghostty windows.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

GHOSTTY_DIR="$HOME/.config/ghostty"

main() {
    echo "Copying Ghostty config..."
    copy_file "$DOTFILES_DIR/ghostty/config.ghostty" "$GHOSTTY_DIR/config.ghostty"

    # SIGUSR2 reloads the config; other signals quit Ghostty
    if pkill -USR2 -x ghostty; then
        echo "Reloaded Ghostty config."
    else
        echo "Ghostty is not running; skipping reload."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
