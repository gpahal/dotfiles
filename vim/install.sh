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

# Not a copy_file: plug.vim is vendored, not edited, so a copy that differs, such as one
# PlugUpgrade wrote, is replaced without a backup
install_plug_vim() {
    if plug_vim_pinned; then
        echo "  vim-plug is already at the pinned version"
        return 0
    fi
    if ! { mkdir -p "$(dirname "$PLUG_VIM")" && replace_file "$DOTFILES_DIR/vim/plug.vim" "$PLUG_VIM" 644; }; then
        echo "  Couldn't write $PLUG_VIM" >&2
        return 1
    fi
    echo "  Installed vim-plug $(cat "$DOTFILES_DIR/vim/plug.vim.version") at $PLUG_VIM"
}

status() {
    vim_files status_file
    status_check "vim-plug at the pinned version (~/.vim/autoload/plug.vim)" plug_vim_pinned
    status_result
}

apply() {
    local status=0
    copy_step "Copying vim config..." vim_files || status=1
    install_plug_vim || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
