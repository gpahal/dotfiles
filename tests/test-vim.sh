#!/bin/bash
set -euo pipefail

# The vimrc, as the vim step installs it, creates its undo dir, starts without errors when
# vim-plug's download fails, leaves no half-written plug.vim behind, and installs vim-plug on a
# later start. curl is stubbed, and the vim-plug it "downloads" is a
# fake with no plugins, so nothing reaches the network.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
assert_exit 0 bash "$REPO_DIR/vim/install.sh"

command -v vim &> /dev/null || skip "vim isn't installed"

PLUG="$HOME/.vim/autoload/plug.vim"

# Start vim on the vimrc and quit. -es skips the vimrc unless -u names it, and exits 1 when a
# command in it fails.
start_vim() {
    vim -Nes -u "$HOME/.vimrc" -c 'qa!' 2>&1
}

# A download that fails partway leaves a partial file where curl was told to write, then fails
stub curl 'while [ $# -gt 0 ]; do case "$1" in -*o) out="$2"; shift ;; esac; shift; done
mkdir -p "$(dirname "$out")" && echo "partial" > "$out"
exit 56'
assert_exit 0 start_vim
assert_not_contains "$RUN_OUTPUT" "E117" "vim output offline"
assert_not_contains "$RUN_OUTPUT" "E121" "vim output offline"
[ ! -e "$PLUG" ] || fail "a failed download left $PLUG"
[ ! -e "$PLUG.tmp" ] || fail "a failed download left $PLUG.tmp"
assert_eq 1 "$(grep -c '^curl' "$STUB_LOG")" "curl runs offline"
[ -d "$HOME/.vim/undodir" ] || fail "vim didn't create ~/.vim/undodir"

# A temp file left by an interrupted start doesn't stop the next download
echo "partial" > "$PLUG.tmp"
stub curl 'while [ $# -gt 0 ]; do case "$1" in -*o) out="$2"; shift ;; esac; shift; done
mkdir -p "$(dirname "$out")" && cat > "$out" << "EOF"
let g:plugs = {}
function! plug#begin(...)
endfunction
function! plug#end()
    let g:fake_plug_loaded = 1
endfunction
command! -nargs=+ -bar Plug :
EOF'
run vim -Nes -u "$HOME/.vimrc" -c 'if !exists("g:fake_plug_loaded") | cquit | endif' -c 'qa!'
assert_eq 0 "$RUN_STATUS" "vim's status once the download works. Its output: $RUN_OUTPUT"
assert_file_contains "$PLUG" "fake_plug_loaded"
[ ! -e "$PLUG.tmp" ] || fail "the download left $PLUG.tmp"

# With vim-plug in place, vim doesn't download it again
: > "$STUB_LOG"
assert_exit 0 start_vim
assert_eq 0 "$(grep -c '^curl' "$STUB_LOG")" "curl runs with vim-plug installed"

# Inside tmux, the mouse works past column 223 and reports drags: Vim uses SGR mouse codes there.
# Vim 9.2 leaves ttymouse at xterm under tmux's TERM, so the vimrc sets it. A tmux server on the
# sandbox's TMUX_TMPDIR runs vim in a pane, which waits for the terminal's replies, then saves
# ttymouse and quits.
if command -v tmux &> /dev/null; then
    out="$SANDBOX/ttymouse"
    cat > "$SANDBOX/probe.vim" << EOF_PROBE
call timer_start(1500, {-> writefile([&ttymouse], '$out') + execute('qa!')})
EOF_PROBE
    unset TMUX
    tmux -f "$REPO_DIR/tmux/tmux.conf" new-session -d -s vim -x 250 -y 50 \
        "vim -N -u '$HOME/.vimrc' -S '$SANDBOX/probe.vim'" 2> /dev/null || true
    for _ in $(seq 50); do
        [ -s "$out" ] && break
        sleep 0.2
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
