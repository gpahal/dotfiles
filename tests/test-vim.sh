#!/bin/bash
set -euo pipefail

# The vim step's status flags a vim-plug copy that differs from the vendored one until a re-run
# restores it. The vimrc downloads nothing, pins every plugin to a commit, and starts without
# errors without vim-plug. Inside tmux, Vim uses SGR mouse codes.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
PLUG="$HOME/.vim/autoload/plug.vim"

assert_exit 0 bash "$REPO_DIR/vim/install.sh"
assert_eq 644 "$(file_mode "$PLUG")" "plug.vim's mode"

# A copy that differs, such as one vim-plug's PlugUpgrade wrote, is missing until a re-run
echo '" changed' >> "$PLUG"
assert_exit 3 bash "$REPO_DIR/vim/install.sh" --status
assert_contains "$RUN_OUTPUT" "missing    vim-plug at the pinned version (~/.vim/autoload/plug.vim)"
assert_exit 0 bash "$REPO_DIR/vim/install.sh"
cmp -s "$REPO_DIR/vim/plug.vim" "$PLUG" || fail "a re-run didn't restore $PLUG"
# One that can't be written, in a dir you can't write to, fails the step. root writes it anyway.
rm "$PLUG"
chmod 555 "$HOME/.vim/autoload"
if [ ! -w "$HOME/.vim/autoload" ]; then
    assert_exit 1 bash "$REPO_DIR/vim/install.sh"
    assert_contains "$RUN_OUTPUT" "Couldn't write $PLUG"
fi
chmod 755 "$HOME/.vim/autoload"
assert_exit 0 bash "$REPO_DIR/vim/install.sh"

# An installed plugin whose checkout isn't at its pin, as after just bump-plugins, is missing until
# a re-run moves it there; a plugin vim hasn't installed yet isn't
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
    assert_contains "$RUN_OUTPUT" "vim plugins already at their pinned commits"
    rm -rf "$HOME/.vim/plugged"
}
subtest plugin_pins
# The repo's own pins, with no plugin installed
assert_exit 0 bash "$REPO_DIR/vim/install.sh" --status

# vim-plug ships with the repo, so the vimrc never downloads it, and vims starting at once can't
# race to write it
assert_file_not_contains "$REPO_DIR/vim/vimrc" "curl"
assert_file_not_contains "$REPO_DIR/vim/vimrc" "raw.githubusercontent.com"
# Every plugin is pinned to a full commit
unpinned="$(grep -E "^ *Plug '" "$REPO_DIR/vim/vimrc" | grep -vE "'commit': '[0-9a-f]{40}'" || true)"
assert_eq "" "$unpinned" "Plug lines without a pinned commit"

command -v vim &> /dev/null || skip "vim isn't installed"

# Start vim on the vimrc and quit. -es skips the vimrc unless -u names it, and exits 1 when a
# command in it fails.
start_vim() {
    vim -Nes -u "$HOME/.vimrc" -c 'qa!' 2>&1
}

# Without vim-plug, vim starts without plugins and without errors
rm "$PLUG"
assert_exit 0 start_vim
assert_not_contains "$RUN_OUTPUT" "E117" "vim output without vim-plug"
# It still highlights syntax, which vim-sensible would otherwise turn on
vim -Nes -u "$HOME/.vimrc" -c "call writefile([exists('g:syntax_on')], '$SANDBOX/syntax')" -c 'qa!' || true
assert_eq 1 "$(cat "$SANDBOX/syntax" 2> /dev/null)" "syntax highlighting without vim-plug"

# Inside tmux, the mouse works past column 223 and reports drags: Vim uses SGR mouse codes there.
# Vim 9.2 leaves ttymouse at xterm under tmux's TERM, so the vimrc sets it. A tmux server on the
# sandbox's TMUX_TMPDIR runs vim in a pane, which waits for the terminal's replies, then saves
# ttymouse and quits.
if command -v tmux &> /dev/null; then
    out="$SANDBOX/ttymouse"
    cat > "$SANDBOX/probe.vim" << EOF_PROBE
call timer_start(400, {-> writefile([&ttymouse], '$out') + execute('qa!')})
EOF_PROBE
    unset TMUX
    tmux -f "$REPO_DIR/tmux/tmux.conf" new-session -d -s vim -x 250 -y 50 \
        "vim -N -u '$HOME/.vimrc' -S '$SANDBOX/probe.vim'" 2> /dev/null || true
    for _ in $(seq 100); do
        [ -s "$out" ] && break
        sleep 0.1
    done
    if [ -s "$out" ]; then
        assert_eq sgr "$(cat "$out")" "ttymouse in a tmux pane"
    else
        fail "vim in a tmux pane didn't save its ttymouse"
    fi
    tmux kill-server 2> /dev/null || true
else
    skip_rest "the tmux mouse check: tmux isn't installed"
fi
test_done
