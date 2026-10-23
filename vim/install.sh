#!/bin/bash
set -euo pipefail

# Copy the vim config, install vim-plug, and move the plugins to their pins.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

PLUG_VIM="$HOME/.vim/autoload/plug.vim"

vim_files() {
    "$1" "$DOTFILES_DIR/vim/vimrc" "$HOME/.vimrc"
}

plug_vim_pinned() {
    cmp -s "$DOTFILES_DIR/vim/plug.vim" "$PLUG_VIM"
}

# Not in vim_files, so just copy-back can't copy a PlugUpgrade'd plug.vim over the vendored one
install_plug_vim() {
    copy_file "$DOTFILES_DIR/vim/plug.vim" "$PLUG_VIM" || return 1
    echo "  Installed vim-plug $(cat "$DOTFILES_DIR/vim/plug.vim.version") at $PLUG_VIM"
}

PLUGGED_DIR="$HOME/.vim/plugged"

vim_plugins() {
    sed -n "s/^ *Plug '\([^']*\)'.*'commit': '\([0-9a-f]\{40\}\)'.*/\1 \2/p" "$DOTFILES_DIR/vim/vimrc"
}

# Skips plugins not yet installed: vim installs them at their pins on start
vim_plugins_off_pin() {
    local repo sha dir
    while read -r repo sha; do
        dir="$PLUGGED_DIR/${repo##*/}"
        [ -d "$dir/.git" ] || continue
        git_head_is "$dir" "$sha" || echo "$repo $sha"
    done < <(vim_plugins)
}

vim_plugins_pinned() {
    [ -z "$(vim_plugins_off_pin)" ]
}

# vim-plug's clones are shallow
pin_vim_plugins() {
    local repo sha status=0
    while read -r repo sha; do
        if git_checkout_pin "$PLUGGED_DIR/${repo##*/}" origin "$sha"; then
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
}

apply() {
    local status=0
    require_cmd git || return 1
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
