#!/bin/bash
set -euo pipefail

# Copy the vim config, install the vim-plug the repo vendors in vim/plug.vim, and move the plugins
# vim-plug installed to the commits the vimrc pins. When vim starts, the vimrc creates its undo
# dir, and vim-plug installs any missing plugins at their pins.

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
    if ! { mkdir -p "$(dirname "$PLUG_VIM")" && replace_file "$DOTFILES_DIR/vim/plug.vim" "$PLUG_VIM" 644; }; then
        echo "  Couldn't write $PLUG_VIM" >&2
        return 1
    fi
    echo "  Installed vim-plug $(cat "$DOTFILES_DIR/vim/plug.vim.version") at $PLUG_VIM"
}

PLUGGED_DIR="$HOME/.vim/plugged"

# Print each Plug line's repo and pinned commit, e.g.
# tpope/vim-sensible 0ce2d843d6f588bb0c8c7eec6449171615dc56d9
vim_plugins() {
    sed -n "s/^ *Plug '\([^']*\)'.*'commit': '\([0-9a-f]\{40\}\)'.*/\1 \2/p" "$DOTFILES_DIR/vim/vimrc"
}

# Print each plugin vim-plug has installed whose checkout isn't at its pin, as "<repo> <commit>".
# One not installed yet isn't listed: vim installs it at its pin when it starts.
vim_plugins_off_pin() {
    local repo sha dir
    while read -r repo sha; do
        dir="$PLUGGED_DIR/${repo##*/}"
        [ -d "$dir/.git" ] || continue
        [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$sha" ] || echo "$repo $sha"
    done < <(vim_plugins)
}

vim_plugins_pinned() {
    [ -z "$(vim_plugins_off_pin)" ]
}

# Move each installed plugin to its pin, as vim-plug's PlugUpdate would, fetching only a commit the
# clone lacks. vim-plug's clones are shallow, and GitHub serves a single commit by its hash.
pin_vim_plugins() {
    local repo sha dir status=0
    require_cmd git || return 1
    while read -r repo sha; do
        dir="$PLUGGED_DIR/${repo##*/}"
        if { git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null ||
            GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch -q --depth 1 origin "$sha"; } &&
            git -C "$dir" checkout -q --detach "$sha"; then
            echo "  Moved vim plugin $repo to ${sha:0:7}"
        else
            echo "  Couldn't move vim plugin $repo to ${sha:0:7}." >&2
            status=1
        fi
    done < <(vim_plugins_off_pin)
    return "$status"
}

vim_items() {
    items_reset
    item "vim-plug at the pinned version (~/.vim/autoload/plug.vim)" "Install vim-plug" \
        plug_vim_pinned install_plug_vim
    item "vim plugins at their pinned commits (~/.vim/plugged)" "Move the vim plugins to their pins" \
        vim_plugins_pinned pin_vim_plugins
}

status() {
    vim_files status_file
    vim_items
    items_status
    status_result
}

apply() {
    local status=0
    copy_step "Copying vim config..." vim_files || status=1
    vim_items
    if ! items_ok; then
        items_apply || status=1
    else
        echo "  vim-plug and the vim plugins already at their pinned versions"
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
