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
test_done
