#!/bin/bash
set -euo pipefail

# The vim step's vendored vim-plug and plugin pins, and a vimrc that starts without vim-plug.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
PLUG="$HOME/.vim/autoload/plug.vim"

assert_exit 0 bash "$REPO_DIR/vim/install.sh"

# A copy that differs, as PlugUpgrade writes, is missing until a re-run
echo '" changed' >> "$PLUG"
assert_exit 3 bash "$REPO_DIR/vim/install.sh" --status
assert_contains "$RUN_OUTPUT" "missing    vim-plug at the pinned version (~/.vim/autoload/plug.vim)"
assert_exit 0 bash "$REPO_DIR/vim/install.sh"
cmp -s "$REPO_DIR/vim/plug.vim" "$PLUG" || fail "a re-run didn't restore $PLUG"

# A plugin off its pin is missing until a re-run; one not installed yet isn't
plugin_pins() {
    local origin="$SANDBOX/vim-plugin" plug="$HOME/.vim/plugged/vim-plugin" old new
    git init -q -b main "$origin"
    git_commit "$origin" --allow-empty -m one
    old="$(git -C "$origin" rev-parse HEAD)"
    git_commit "$origin" --allow-empty -m two
    new="$(git -C "$origin" rev-parse HEAD)"
    git clone -q "file://$origin" "$plug"
    git -C "$plug" checkout -q --detach "$old"
    load_script vim/install.sh
    replace_fn vim_plugins "echo 'me/vim-plugin $new'; echo 'me/not-installed $new'"
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    vim plugins at their pinned commits (~/.vim/plugged)"
    assert_exit 0 apply
    assert_contains "$RUN_OUTPUT" "Moved vim plugin me/vim-plugin to ${new:0:7}"
    assert_eq "$new" "$(git -C "$plug" rev-parse HEAD)" "the plugin's commit after a re-run"
    assert_exit 0 status
    assert_exit 0 apply
    assert_contains "$RUN_OUTPUT" "vim-plug and the vim plugins already at their pinned versions"
    rm -rf "$HOME/.vim/plugged"
}
subtest plugin_pins

# Vendored vim-plug: vims starting at once can't race to download it
assert_file_not_contains "$REPO_DIR/vim/vimrc" "curl"
assert_file_not_contains "$REPO_DIR/vim/vimrc" "raw.githubusercontent.com"
unpinned="$(grep -E "^ *Plug '" "$REPO_DIR/vim/vimrc" | grep -vE "'commit': '[0-9a-f]{40}'" || true)"
assert_eq "" "$unpinned" "Plug lines without a pinned commit"

command -v vim &> /dev/null || skip "vim isn't installed"

# -es skips the vimrc unless -u names it, and exits 1 when a command in it fails
start_vim() {
    vim -Nes -u "$HOME/.vimrc" -c 'qa!' 2>&1
}

# -c commands run before VimEnter, so vim quits without installing anything
vim -Nes -u "$HOME/.vimrc" -c "source $HOME/.vimrc" \
    -c "redir! > $SANDBOX/autocmds | autocmd dotfiles_plug_install VimEnter | redir END" -c 'qa!' || true
assert_eq 1 "$(grep -c PlugInstall "$SANDBOX/autocmds" 2> /dev/null)" "plugin-install autocmds after sourcing the vimrc twice"

rm "$PLUG"
assert_exit 0 start_vim
assert_not_contains "$RUN_OUTPUT" "E117" "vim output without vim-plug"
test_done
