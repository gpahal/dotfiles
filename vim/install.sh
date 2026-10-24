#!/bin/bash
set -euo pipefail

# Copy the vim config, install vim-plug, pin the plugins, and install vim-go's Go tools.

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

# "<tool> <package>" for each tool the pinned vim-go's :GoInstallBinaries installs, which
# just bump-plugins writes
VIM_GO_TOOLS="$DOTFILES_DIR/vim/vim-go-tools"

vim_go_packages() {
    awk '!/^#/ && NF == 2' "$VIM_GO_TOOLS"
}

# Where go install puts tools, as vim-go does
go_bin_dir() {
    local dir
    dir="$(go env GOBIN 2>/dev/null)" || return 1
    [ -n "$dir" ] || dir="$(go env GOPATH 2>/dev/null | cut -d: -f1)/bin"
    [ "$dir" != /bin ] && echo "$dir"
}

# Prints each tool that's neither in go's bin dir nor on PATH, as vim-go looks for them
vim_go_tools_missing() {
    local name package dir=""
    ! command -v go &>/dev/null || dir="$(go_bin_dir)" || true
    while read -r name package; do
        { [ -n "$dir" ] && [ -x "$dir/$name" ]; } || command -v "$name" &>/dev/null || echo "$name $package"
    done < <(vim_go_packages)
}

# Sets ITEM_DETAIL to the tools missing
vim_go_tools_installed() {
    local missing
    missing="$(vim_go_tools_missing | awk '{ print $1 }')"
    [ -n "$missing" ] || return 0
    ITEM_DETAIL="$(join_lines ', ' <<< "$missing")"
    command -v go &>/dev/null || ITEM_DETAIL="$ITEM_DETAIL; $(missing_cmd_hint go)"
    return 1
}

# What :GoInstallBinaries does, outside vim, so a failure shows
install_vim_go_tools() {
    local name package status=0
    require_cmd go || return 1
    while read -r name package; do
        echo "  Installing $name ($package), which vim-go uses..."
        if ! go install "$package"; then
            echo "  Couldn't install $name. Run go install $package to retry." >&2
            status=1
        fi
    done < <(vim_go_tools_missing)
    return "$status"
}

vim_items() {
    items_reset
    item "vim-plug at the pinned version (~/.vim/autoload/plug.vim)" "Install vim-plug" \
        plug_vim_pinned install_plug_vim
    item "vim plugins at their pinned commits (~/.vim/plugged)" "Move the vim plugins to their pins" \
        vim_plugins_pinned pin_vim_plugins
    item "vim-go's Go tools, which :GoInstallBinaries installs" "Install vim-go's Go tools" \
        vim_go_tools_installed install_vim_go_tools
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
    items_apply_confirmed --done "  vim-plug, the vim plugins' pins, and vim-go's tools already set up" || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
