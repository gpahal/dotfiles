#!/bin/bash
set -euo pipefail

# Copy the lazygit config. On macOS, lazygit reads ~/Library/Application Support/lazygit, not
# ~/.config/lazygit, unless XDG_CONFIG_HOME is set (`lazygit --print-config-dir` shows which).

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
    echo "Copying lazygit config..."
    copy_file "$DOTFILES_DIR/lazygit/config.yml" "${XDG_CONFIG_HOME:-$HOME/Library/Application Support}/lazygit/config.yml"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
