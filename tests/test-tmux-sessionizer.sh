#!/bin/bash
set -euo pipefail

# tmux-sessionizer opens a session for the project fzf picks from ~/Dev/<group>/<project>, or the
# directory given: inside tmux it creates the session detached and switches to it, and outside
# tmux it attaches with new-session -A. Two projects with the same name get api and api_2, a
# project goes back to its session whatever names are free, also under LC_ALL=C, a . in the name
# becomes _, fd and find list the same projects, a cancelled pick does nothing, and a failed
# listing still lets fzf pick. Without fzf it fails with bash's "command not found" (127). Runs a
# tmux server on the sandbox's TMUX_TMPDIR.

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

# With api gone, js/api still goes to its api_2, not to a new api
"$REAL_TMUX" kill-session -t =api
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_file_not_contains "$STUB_LOG" "new-session"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api_2"

# Listing the projects fails, as find or fd does on a directory it can't read: the pick still opens
pick "$HOME/Dev/go/api"
stub fd 'echo "'"$HOME/Dev/go/api"'"; exit 1'
: > "$STUB_LOG"
assert_exit 0 bash "$SESSIONIZER"
assert_file_contains "$STUB_LOG" "tmux switch-client -t =api"
rm "$STUB_DIR/fd"

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
# No project matched the query, and a path that isn't a directory
stub fzf 'cat > /dev/null; exit 1'
assert_exit 0 bash "$SESSIONIZER"
assert_exit 1 bash "$SESSIONIZER" "$HOME/Dev/nope"
assert_contains "$RUN_OUTPUT" "tmux-sessionizer: not a directory: $HOME/Dev/nope"

# No fzf: bash's error, and a failure, so prefix+f's popup stays open to show it
hide fzf
: > "$STUB_LOG"
assert_exit 127 bash "$SESSIONIZER"
assert_contains "$RUN_OUTPUT" "fzf: command not found"
assert_file_not_contains "$STUB_LOG" "tmux"
test_done
