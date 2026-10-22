#!/bin/bash
set -euo pipefail

# please runs the line typed before it as root. Each case feeds an interactive zsh on stdin.
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"

stub sudo

# No prompt, so the output holds only what the lines print; -d skips the system's startup files
mkdir -p "$SANDBOX/zdot"
printf '%s\n' 'PS1= PS2= PROMPT_EOL_MARK=' 'unset HOMEBREW_PREFIX' 'compdef() { :; }' \
    'autoload -U add-zsh-hook' \
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

# hist_ignore_space keeps the line out of history, but it's still the line typed before please
: > "$STUB_LOG"
assert_exit 0 interactive 'echo kept' ' echo spaced' please
assert_eq "sudo zsh -c  echo spaced" "$(cat "$STUB_LOG")" "a line with a leading space"

: > "$STUB_LOG"
assert_exit 0 interactive 'echo twice' please please
assert_eq "$(printf '%s\n' 'sudo zsh -c echo twice' 'sudo zsh -c echo twice')" "$(cat "$STUB_LOG")" \
    "please twice"

# A line zsh doesn't run is still the line typed before please
for line in 'echo oops )' '# a note'; do
    : > "$STUB_LOG"
    assert_exit 0 interactive 'echo older' "$line" please
    assert_eq "sudo zsh -c $line" "$(cat "$STUB_LOG")" "please after '$line'"
done

: > "$STUB_LOG"
assert_exit 0 interactive 'echo spaced' ' please' 'please ' 'echo again; please'
assert_eq "$(printf 'sudo zsh -c echo spaced\n%.0s' 1 2 3)" "$(cat "$STUB_LOG")" "please with spaces"

# With share_history, the history holds other shells' commands, which please mustn't run
: > "$STUB_LOG"
printf ': 1:0;echo other\n' > "$HOME/.zsh_history"
assert_exit 1 interactive please
assert_contains "$RUN_OUTPUT" "no earlier command"
assert_eq "" "$(cat "$STUB_LOG")" "please in a new shell"
test_done
