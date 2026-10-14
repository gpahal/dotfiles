#!/bin/bash
set -euo pipefail

# Copy the vim config. When vim starts, the vimrc creates its undo dir, and vim-plug installs
# itself and any missing plugins.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Pass the file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
vim_files() {
    "$1" "$DOTFILES_DIR/vim/vimrc" "$HOME/.vimrc"
}

status() {
    vim_files status_file
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Copying vim config..."
    vim_files copy_file
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
