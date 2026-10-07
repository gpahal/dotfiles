#!/bin/bash
set -euo pipefail

# Copy the vim config. vim-plug installs itself and the plugins on first open.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
    echo "Copying vim config..."
    copy_file "$DOTFILES_DIR/vim/vimrc" "$HOME/.vimrc"
    mkdir -p "$HOME/.vim/undodir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
