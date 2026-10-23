#!/bin/bash
set -euo pipefail

# zsh/main.zsh in a login terminal: no zsh errors, extendedglob off, and _cached_init's cache.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
in_terminal_available || skip "script isn't installed"
# CLAUDECODE turns off the terminal-only options and reminders
unset CLAUDECODE
stub_login_shell_zsh
assert_exit 0 bash "$REPO_DIR/zsh/install.sh"
stub brew 'exit 1'
# path_helper puts /opt/homebrew/bin ahead of the stubs, so ~/.zprofile puts them back
stub mise
printf 'path=(%q $path)\n' "$STUB_DIR" >> "$HOME/.zprofile"

WORK="$SANDBOX/work"
mkdir -p "$WORK"
ERR="$SANDBOX/stderr"

# Usage: zsh_in_terminal <TERM> <commands>; stderr goes to $ERR
zsh_in_terminal() {
    in_terminal /bin/sh -c 'cd "$1" && TERM=$2 exec zsh -lic "$3" 2> "$4"' sh "$WORK" "$@" "$ERR"
}

# CI doesn't install bat or eza
stub bat
stub eza
checks='echo loaded; print -r -- main^'
# Only zsh's own errors count: real starship, atuin, and zoxide stderr flaked under parallel runs
zsh_errors() {
    grep -qE -e '^[^ :]+:[0-9]+: ' -e '^[^ :]+: command not found: ' -e '^zsh:' -e "$HOME/\.z"
}
for term in xterm-256color dumb; do
    output="$(zsh_in_terminal "$term" "$checks")"
    assert_contains "$output" "loaded" "output with TERM=$term"
    if zsh_errors < "$ERR"; then
        fail "the zsh config printed an error with TERM=$term:"
        _show "$(cat "$ERR")"
    fi
done
# extendedglob would make git's HEAD^ a pattern
assert_contains "$output" "main^" "main^ in a terminal"

stub fakeinit 'echo "echo init-$*"'
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; _cached_init fakeinit one; _cached_init fakeinit two" 2>&1)"
assert_contains "$output" "init-one" "_cached_init output"
assert_contains "$output" "init-two" "_cached_init output"
assert_eq 2 "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs"
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; _cached_init fakeinit two" 2>&1)"
assert_contains "$output" "init-two" "cached _cached_init output"
assert_eq 2 "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs with the cache in place"
cache="$HOME/.cache/zsh/fakeinit-init.zsh"
assert_eq "$cache" "$(find "$cache" -perm 600)" "the cache with mode 600"
# One others could write is rewritten, even under umask 0
chmod 666 "$cache"
zsh -c "umask 000; source '$HOME/.zsh/main.zsh'; _cached_init fakeinit two" > /dev/null 2>&1
assert_eq 3 "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs with a writable cache"
assert_eq "$cache" "$(find "$cache" -perm 600)" "the rewritten cache with mode 600"
test_done
