#!/bin/bash
set -euo pipefail

# please shows the line typed before it, then runs it as root: a multi-line command keeps its
# newlines, a line typed with a leading space or one zsh didn't run counts, and a second please
# runs the same command.
# Each case feeds lines to an interactive zsh on stdin, so its hooks and history run as they do
# at a prompt.
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"

stub sudo

# Run the given lines in an interactive zsh, with no prompt, so the output holds only what the
# lines print. Its .zshrc sources the options, history settings, aliases, and functions, and zsh
# then reads ~/.zsh_history, as at a terminal. -d skips the system's startup files.
mkdir -p "$SANDBOX/zdot"
printf '%s\n' 'PS1= PS2= PROMPT_EOL_MARK=' 'unset HOMEBREW_PREFIX' 'compdef() { :; }' \
    "source '$REPO_DIR/zsh/options.zsh'" "source '$REPO_DIR/zsh/history.zsh'" \
    "source '$REPO_DIR/zsh/aliases.zsh'" \
    "source '$REPO_DIR/zsh/functions.zsh'" > "$SANDBOX/zdot/.zshrc"
interactive() {
    printf '%s\n' "$@" | ZDOTDIR="$SANDBOX/zdot" zsh -di 2>&1
}

assert_exit 0 interactive 'echo first' please
assert_contains "$RUN_OUTPUT" "sudo: echo first" "what please prints"
assert_eq "sudo zsh -c echo first" "$(cat "$STUB_LOG")" "what please runs"

# fc -n would print the newline as \n, which zsh -c reads as n
: > "$STUB_LOG"
assert_exit 0 interactive '{ echo one' 'echo two }' please
assert_eq "$(printf '%s\n' 'sudo zsh -c { echo one' 'echo two }')" "$(cat "$STUB_LOG")" "a multi-line command"

# hist_ignore_space keeps the line out of history, but it's still the command typed before please
: > "$STUB_LOG"
assert_exit 0 interactive 'echo kept' ' echo spaced' please
assert_eq "sudo zsh -c  echo spaced" "$(cat "$STUB_LOG")" "a line with a leading space"

: > "$STUB_LOG"
assert_exit 0 interactive 'echo twice' please please
assert_eq "$(printf '%s\n' 'sudo zsh -c echo twice' 'sudo zsh -c echo twice')" "$(cat "$STUB_LOG")" \
    "please twice"

# A line zsh doesn't run, such as one with a parse error or only a comment, is still the line typed
# before please, so please never reaches past it to an older command
for line in 'echo oops )' '# a note'; do
    : > "$STUB_LOG"
    assert_exit 0 interactive 'echo older' "$line" please
    assert_eq "sudo zsh -c $line" "$(cat "$STUB_LOG")" "please after '$line'"
done

# A please with spaces around it is a please too, and please on a line after another command runs
# the line before that one
: > "$STUB_LOG"
assert_exit 0 interactive 'echo spaced' ' please' 'please ' 'echo again; please'
assert_eq "$(printf 'sudo zsh -c echo spaced\n%.0s' 1 2 3)" "$(cat "$STUB_LOG")" "please with spaces"

# With share_history, the history holds other shells' commands, which please mustn't run. A new
# shell has typed none.
: > "$STUB_LOG"
printf ': 1:0;echo other\n' > "$HOME/.zsh_history"
assert_exit 1 interactive please
assert_contains "$RUN_OUTPUT" "no earlier command"
assert_eq "" "$(cat "$STUB_LOG")" "please in a new shell"

# please was once an alias, which a shell started before the zsh step still has when it sources
# ~/.zshrc again. The definition still parses, and the functions after it still load.
probe_alias() {
    zsh -fc '
        unset HOMEBREW_PREFIX
        compdef() { :; }
        alias please='\''sudo zsh -c "$(fc -ln -1)"'\''
        source "$1/zsh/functions.zsh"
        unalias please
        whence -w please g
    ' zsh "$REPO_DIR"
}
assert_exit 0 probe_alias
assert_eq "$(printf '%s\n' 'please: function' 'g: function')" "$RUN_OUTPUT" "please after the old alias"
test_done
