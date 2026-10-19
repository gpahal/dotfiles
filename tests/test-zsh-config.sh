#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
command -v script &>/dev/null || skip "script isn't installed"
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

# Usage: in_terminal <TERM> <commands>; stderr goes to $ERR
in_terminal() {
    local cmd
    cmd="$(printf '%q ' /bin/sh -c 'cd "$1" && TERM=$2 exec zsh -lic "$3" 2> "$4"' sh "$WORK" "$@" "$ERR")"
    if [[ "$OSTYPE" == darwin* ]]; then
        script -q /dev/null /bin/sh -c "$cmd"
    else
        # script runs the command with $SHELL, and %q output is bash quoting
        SHELL=/bin/bash script -qec "$cmd" /dev/null
    fi < /dev/null | tr -d '\r'
}

# CI doesn't install bat or eza
stub bat
stub eza
# eza reads a bare -F as --classify [WHEN], taking a following path as WHEN
touch "$WORK/main.go" "$WORK/main_test.go"
checks='echo loaded; print -r -- main^; [[ -o extendedglob ]] && echo extendedglob-on
print -r -- "mise=$(whence -p mise)"; for a in l la ll lla; do alias $a; done; true'
# Only zsh's own errors count: real starship, atuin, and zoxide stderr flaked under parallel runs
zsh_errors() {
    grep -qE -e '^[^ :]+:[0-9]+: ' -e '^[^ :]+: command not found: ' -e '^zsh:' -e "$HOME/\.z"
}
for line in "zsh:1: command not found: nocmd" "zsh: command not found: nocmd" \
    "_cached_init: command not found: nocmd" "_cached_init:4: parse error near \`)'" \
    "$HOME/.zprofile:1: command not found: nocmd" "(eval):3: command not found: nocmd" \
    "$HOME/.zsh/main.zsh:12: no such file or directory: x"; do
    zsh_errors <<< "$line" || fail "zsh_errors missed: $line"
done
for line in "Error: database is locked" "[WARN] - (starship::config): bad key" \
    "thread 'main' panicked at src/main.rs:12:5:" "zoxide: warning: no match found"; do
    ! zsh_errors <<< "$line" || fail "zsh_errors counted a tool's output: $line"
done
for term in xterm-256color dumb; do
    output="$(in_terminal "$term" "$checks")"
    assert_contains "$output" "loaded" "output with TERM=$term"
    assert_contains "$output" "mise=$STUB_DIR/mise" "the mise a terminal finds with TERM=$term"
    if zsh_errors < "$ERR"; then
        fail "the zsh config printed an error with TERM=$term:"
        _show "$(cat "$ERR")"
    fi
done
assert_contains "$output" "main^" "main^ in a terminal"
assert_not_contains "$output" "extendedglob-on" "options in a terminal"
for a in "l='eza --classify=auto'" "la='eza -a --classify=auto'" "ll='eza -l --classify=auto'" \
    "lla='eza -al --classify=auto'"; do
    assert_contains "$output" "$a" "the eza listing aliases"
done

stub fakeinit 'echo "echo init-$*"'
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; _cached_init fakeinit one; _cached_init fakeinit two" 2>&1)"
assert_contains "$output" "init-one" "_cached_init output"
assert_contains "$output" "init-two" "_cached_init output"
assert_eq 2 "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs"
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; _cached_init fakeinit two" 2>&1)"
assert_contains "$output" "init-two" "cached _cached_init output"
assert_eq 2 "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs with the cache in place"
run_with_file() {
    output="$(zsh -c "source '$HOME/.zsh/main.zsh'; _cached_init -f '$1' fakeinit two" 2>&1 || true)"
    assert_contains "$output" "init-two" "_cached_init -f output ($2)"
    assert_eq "$3" "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs ($2)"
}
echo one > "$SANDBOX/fakeinit.conf"
touch -t 200001010000 "$SANDBOX/fakeinit.conf"
run_with_file "$SANDBOX/fakeinit.conf" "first -f file" 3
run_with_file "$SANDBOX/fakeinit.conf" "unchanged -f file" 3
touch -t 203001010000 "$SANDBOX/fakeinit.conf"
run_with_file "$SANDBOX/fakeinit.conf" "newer -f file" 4
rm "$SANDBOX/fakeinit.conf"
run_with_file "$SANDBOX/fakeinit.conf" "deleted -f file" 5

# mise must load after command-not-found.zsh, or that replaces mise's wrapping handler
export HOMEBREW_PREFIX="$SANDBOX/brew" HOMEBREW_REPOSITORY="$SANDBOX/brew"
mkdir -p "$HOMEBREW_REPOSITORY/Library/Homebrew/command-not-found"
echo 'command_not_found_handler() { print "homebrew: $1"; return 127; }' \
    > "$HOMEBREW_REPOSITORY/Library/Homebrew/command-not-found/handler.sh"
stub mise '[ "$*" != "activate zsh" ] || echo '\''
(( $+functions[command_not_found_handler] )) && functions[_command_not_found_handler]=$functions[command_not_found_handler]
command_not_found_handler() { print "mise: $1"; _command_not_found_handler "$@"; }'\'
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; nosuchtool" 2>&1)" || true
assert_contains "$output" "mise: nosuchtool" "the handler left after loading"
assert_not_contains "$output" "_command_not_found_handler" "the handler mise wraps"
export HOMEBREW_PREFIX="$SANDBOX/no-homebrew"
unset HOMEBREW_REPOSITORY
test_done
