#!/bin/bash
set -euo pipefail

# Copy the vim config, and install the vim-plug the repo vendors in vim/plug.vim. When vim starts,
# the vimrc creates its undo dir, and vim-plug installs any missing plugins at their pinned
# commits.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PLUG_VIM="$HOME/.vim/autoload/plug.vim"

# Pass the file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
vim_files() {
    "$1" "$DOTFILES_DIR/vim/vimrc" "$HOME/.vimrc"
}

plug_vim_pinned() {
    cmp -s "$DOTFILES_DIR/vim/plug.vim" "$PLUG_VIM"
}

# Not a copy_file: plug.vim is vendored, not edited, so a copy that differs, such as one an older
# vimrc downloaded or PlugUpgrade wrote, is replaced without a backup
install_plug_vim() {
    local tmp
    if plug_vim_pinned; then
        echo "  vim-plug is already at the pinned version"
        return 0
    fi
    mkdir -p "$(dirname "$PLUG_VIM")" && tmp="$(mktemp)" || return 1
    if cp "$DOTFILES_DIR/vim/plug.vim" "$tmp" && write_back "$tmp" "$PLUG_VIM"; then
        echo "  Installed vim-plug $(cat "$DOTFILES_DIR/vim/plug.vim.version") at $PLUG_VIM"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

status() {
    vim_files status_file
    status_check "vim-plug at the pinned version (~/.vim/autoload/plug.vim)" plug_vim_pinned
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    local status=0
    echo "Copying vim config..."
    vim_files copy_file || status=1
    install_plug_vim || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
