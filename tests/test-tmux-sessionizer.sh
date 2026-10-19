#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v tmux &> /dev/null || skip "tmux isn't installed"

SESSIONIZER="$REPO_DIR/tmux/bin/tmux-sessionizer"
# The real tmux runs all but the two commands that need a terminal
REAL_TMUX="$(command -v tmux)"
stub tmux 'case " $* " in
    " switch-client "* | " new-session -A "*) exit 0 ;;
esac
exec "'"$REAL_TMUX"'" "$@"'
mkdir -p "$HOME/Dev/go/api" "$HOME/Dev/js/api" "$HOME/Dev/web/site.io"
pick() {
    stub fzf 'cat > "'"$SANDBOX"'/fzf-input"; echo "'"$1"'"'
}
session_path() {
    "$REAL_TMUX" display-message -p -t "=$1:" '#{session_path}'
}

tmux -f /dev/null new-session -d -s main
TMUX="$TMUX_TMPDIR/tmux-$(id -u)/default,1,0"
export TMUX

pick "$HOME/Dev/go/api"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_eq "$HOME/Dev/go/api" "$(session_path api)" "the api session's path"
assert_file_contains "$STUB_LOG" "tmux new-session -d -s api -c $HOME/Dev/go/api"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api"
assert_file_contains "$SANDBOX/fzf-input" "$HOME/Dev/js/api"
assert_file_contains "$SANDBOX/fzf-input" "$HOME/Dev/web/site.io"

: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_file_not_contains "$STUB_LOG" "new-session"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api"

pick "$HOME/Dev/js/api"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_eq "$HOME/Dev/js/api" "$(session_path api_2)" "the api_2 session's path"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api_2"

rm "$STUB_DIR/fzf"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/web/site.io"
assert_eq "$HOME/Dev/web/site.io" "$(session_path site_io)" "the site_io session's path"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =site_io"

unset TMUX
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/go/api"
assert_file_contains "$STUB_LOG" "tmux new-session -A -s api -c $HOME/Dev/go/api"
assert_file_not_contains "$STUB_LOG" "switch-client"
# Under the C locale tmux prints a tab in list-sessions' output as _ unless given -u
: > "$STUB_LOG"
LC_ALL=C assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/go/api"
assert_file_contains "$STUB_LOG" "tmux new-session -A -s api -c $HOME/Dev/go/api"

# A relative directory ignores CDPATH, which cd would follow and print
TMUX="$TMUX_TMPDIR/tmux-$(id -u)/default,1,0"
export TMUX
: > "$STUB_LOG"
assert_exit 0 env CDPATH="$HOME/Dev/go" bash -c 'cd "$1" && exec bash "$2" api' bash "$HOME/Dev/js" "$SESSIONIZER"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api_2"
assert_file_not_contains "$STUB_LOG" "new-session"

# tmux expands formats in a new session's name and directory
mkdir -p "$HOME/Dev/web/C#{host}x"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/web/C#{host}x"
assert_eq "$HOME/Dev/web/C#{host}x" "$(session_path 'C_{host}x')" "the path of the session for C#{host}x"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =C_{host}x"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/web/C#{host}x"
assert_file_not_contains "$STUB_LOG" "new-session"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =C_{host}x"
unset TMUX
rmdir "$HOME/Dev/web/C#{host}x"

# fd and find must list the same projects
mkdir -p "$HOME/Dev/.hidden/proj" "$HOME/Dev/go/.cache"
echo site.io > "$HOME/Dev/web/.ignore"
expected="$(printf '%s\n' "$HOME/Dev/go/api" "$HOME/Dev/js/api" "$HOME/Dev/web/site.io")"
listed() {
    sed 's:/$::' "$SANDBOX/fzf-input" | sort
}
if command -v fd &>/dev/null; then
    stub fzf 'cat > "'"$SANDBOX"'/fzf-input"; exit 130'
    assert_exit 0 bash "$SESSIONIZER"
    assert_eq "$expected" "$(listed)" "the projects fd lists"
else
    skip_rest "listing projects with fd: fd isn't installed"
fi
hide fd
stub fzf 'cat > "'"$SANDBOX"'/fzf-input"; exit 130'
assert_exit 0 bash "$SESSIONIZER"
assert_eq "$expected" "$(listed)" "the projects find lists"

stub fzf 'cat > /dev/null; exit 130'
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_eq "fzf" "$(cat "$STUB_LOG")" "commands run after a cancelled pick"
test_done
