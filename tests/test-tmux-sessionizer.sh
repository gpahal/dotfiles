#!/bin/bash
set -euo pipefail

# tmux-sessionizer opens a session for the project fzf picks from ~/Dev/<group>/<project>, or the
# directory given: inside tmux it creates the session detached and switches to it, and outside
# tmux it attaches with new-session -A, also under LC_ALL=C. Two projects with the same name get
# api and api_2, a . or a # in the name becomes _, a # stays literal in the session's path, a
# relative directory is the one in the current directory whatever CDPATH says, fd and find list
# the same projects, and a cancelled pick does nothing. Runs a tmux server on the sandbox's
# TMUX_TMPDIR.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v tmux &> /dev/null || skip "tmux isn't installed"

SESSIONIZER="$REPO_DIR/tmux/bin/tmux-sessionizer"
# The real tmux runs every command but the two that need a terminal: switch-client, which needs
# an attached client, and new-session -A, which attaches. The stub logs those, so the test sees
# them.
REAL_TMUX="$(command -v tmux)"
stub tmux 'case " $* " in
    " switch-client "* | " new-session -A "*) exit 0 ;;
esac
exec "'"$REAL_TMUX"'" "$@"'
mkdir -p "$HOME/Dev/go/api" "$HOME/Dev/js/api" "$HOME/Dev/web/site.io"
# pick <dir>: fzf, given the project list on stdin, picks dir
pick() {
    stub fzf 'cat > "'"$SANDBOX"'/fzf-input"; echo "'"$1"'"'
}
# Print the path of a session
session_path() {
    "$REAL_TMUX" display-message -p -t "=$1:" '#{session_path}'
}

tmux -f /dev/null new-session -d -s main
# Inside tmux. tmux finds the server's socket from $TMUX.
TMUX="$TMUX_TMPDIR/tmux-$(id -u)/default,1,0"
export TMUX

# A pick: a new session, named after the directory, and a switch to it
pick "$HOME/Dev/go/api"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_eq "$HOME/Dev/go/api" "$(session_path api)" "the api session's path"
assert_file_contains "$STUB_LOG" "tmux new-session -d -s api -c $HOME/Dev/go/api"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api"
assert_file_contains "$SANDBOX/fzf-input" "$HOME/Dev/js/api"
assert_file_contains "$SANDBOX/fzf-input" "$HOME/Dev/web/site.io"

# The same pick again: a switch to the session that's there
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_file_not_contains "$STUB_LOG" "new-session"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api"

# Another project named api gets api_2
pick "$HOME/Dev/js/api"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_eq "$HOME/Dev/js/api" "$(session_path api_2)" "the api_2 session's path"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api_2"

# A directory as the argument skips fzf, and . in the name becomes _
rm "$STUB_DIR/fzf"
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/web/site.io"
assert_eq "$HOME/Dev/web/site.io" "$(session_path site_io)" "the site_io session's path"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =site_io"

# Outside tmux, it attaches to the session, creating it if it's missing
unset TMUX
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/go/api"
assert_file_contains "$STUB_LOG" "tmux new-session -A -s api -c $HOME/Dev/go/api"
assert_file_not_contains "$STUB_LOG" "switch-client"
# Under the C locale too, where tmux prints a tab in list-sessions' output as _ unless given -u
: > "$STUB_LOG"
LC_ALL=C assert_exit 0 bash "$SESSIONIZER" "$HOME/Dev/go/api"
assert_file_contains "$STUB_LOG" "tmux new-session -A -s api -c $HOME/Dev/go/api"

# Inside tmux again. A relative directory is the one in the current directory, even when CDPATH
# has one of the same name, which cd would go to and print.
TMUX="$TMUX_TMPDIR/tmux-$(id -u)/default,1,0"
export TMUX
: > "$STUB_LOG"
assert_exit 0 env CDPATH="$HOME/Dev/go" bash -c 'cd "$1" && exec bash "$2" api' bash "$HOME/Dev/js" "$SESSIONIZER"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api_2"
assert_file_not_contains "$STUB_LOG" "new-session"

# tmux expands formats in a new session's name and directory, so a # in the directory name stays
# literal in the path, becomes _ in the name, and a second run goes back to the session
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

# fd and find list the same projects: hidden groups and projects stay out, an .ignore file
# doesn't hide one, and the dots in the sandbox's own path don't matter
mkdir -p "$HOME/Dev/.hidden/proj" "$HOME/Dev/go/.cache"
echo site.io > "$HOME/Dev/web/.ignore"
expected="$(printf '%s\n' "$HOME/Dev/go/api" "$HOME/Dev/js/api" "$HOME/Dev/web/site.io")"
# Print the projects fzf was given, sorted, without fd's trailing /
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

# A cancelled pick
stub fzf 'cat > /dev/null; exit 130'
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_eq "fzf" "$(cat "$STUB_LOG")" "commands run after a cancelled pick"
test_done
