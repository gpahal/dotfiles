#!/bin/bash
set -euo pipefail

# please shows the last command in history before it runs it as root. With hist_ignore_space, a
# line typed with a leading space never reaches history, so the last command there may not be the
# last one typed.
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"

stub sudo

probe() {
    zsh -fc '
        unset HOMEBREW_PREFIX
        # Completion is not loaded here
        compdef() { :; }
        source "$1/zsh/aliases.zsh"
        source "$1/zsh/functions.zsh"
        print -s "echo first"
        # eval, so an alias defined above would expand
        eval please
    ' zsh "$REPO_DIR"
}

assert_exit 0 probe
assert_eq "sudo: echo first" "$RUN_OUTPUT" "what please prints"
assert_file_contains "$STUB_LOG" "sudo zsh -c echo first"

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
        print -s "echo second"
        please
    ' zsh "$REPO_DIR"
}
: > "$STUB_LOG"
assert_exit 0 probe_alias
assert_eq "$(printf '%s\n' 'please: function' 'g: function' 'sudo: echo second')" "$RUN_OUTPUT" "please after the old alias"
assert_file_contains "$STUB_LOG" "sudo zsh -c echo second"
test_done
