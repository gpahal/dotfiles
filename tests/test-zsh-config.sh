#!/bin/bash
set -euo pipefail

# The whole zsh config, as the zsh step installs it, loads in a terminal without printing to
# stderr, also with TERM=dumb. Checks what it sets up there: ^ isn't a glob operator, the eza
# aliases give --classify its value, _cached_init keys its cache on the init arguments and its -f
# file, and mise's command-not-found handler wraps the config's. Uses the tools installed on this
# machine (starship, atuin, ...), each with the sandbox HOME, and stubs mise, bat, and eza.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
command -v script &>/dev/null || skip "script isn't installed"
# Under Claude Code, CLAUDECODE would turn off the terminal-only options and reminders
unset CLAUDECODE
stub_login_shell_zsh
assert_exit 0 bash "$REPO_DIR/zsh/install.sh"
stub brew 'exit 1'
# mise is a sentinel, and the config runs mise when it finds one on PATH. /etc/zprofile's
# path_helper puts the system's dirs, /opt/homebrew/bin among them on macOS, ahead of the stubs,
# so ~/.zprofile puts them back in front.
stub mise
printf 'path=(%q $path)\n' "$STUB_DIR" >> "$HOME/.zprofile"

WORK="$SANDBOX/work"
mkdir -p "$WORK"
ERR="$SANDBOX/stderr"

# Run commands in an interactive login zsh in a pseudo-terminal, from $WORK, printing its output
# without carriage returns. Its stderr goes to $ERR. Usage: in_terminal <TERM> <commands>
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

# bat and eza are stubbed, since CI doesn't install them
stub bat
stub eza
# ^ is a plain character, so git's HEAD^ and main^ reach git as typed, even when files match the
# pattern ^ would make. eza reads a bare -F as --classify [WHEN], so it would take a path after it
# as the WHEN.
touch "$WORK/main.go" "$WORK/main_test.go"
checks='echo loaded; print -r -- main^; [[ -o extendedglob ]] && echo extendedglob-on
print -r -- "mise=$(whence -p mise)"; for a in l la ll lla; do alias $a; done; true'
# Succeeds when stdin holds an error zsh printed. The shell runs the real starship, atuin, and
# zoxide, whose stderr once failed the check under a parallel test run, so only zsh's own errors
# count. zsh starts each with where it ran: "<file or function>:<line>:", as in "zsh:1:",
# "(eval):2:", "$HOME/.zprofile:1:", or "_cached_init:3:", but "<function>:" alone for a command
# not found in a function, and "zsh:" alone for one typed at the prompt.
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

# _cached_init regenerates its cache when the arguments change, not only when the binary does
stub fakeinit 'echo "echo init-$*"'
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; _cached_init fakeinit one; _cached_init fakeinit two" 2>&1)"
assert_contains "$output" "init-one" "_cached_init output"
assert_contains "$output" "init-two" "_cached_init output"
assert_eq 2 "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs"
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; _cached_init fakeinit two" 2>&1)"
assert_contains "$output" "init-two" "cached _cached_init output"
assert_eq 2 "$(grep -c '^fakeinit' "$STUB_LOG")" "fakeinit runs with the cache in place"
# With -f, it regenerates when that file, such as the tool's config, changes or goes away
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

# mise's activation wraps the command-not-found handler already defined, so it must load after
# command-not-found.zsh, or that replaces mise's. The stub prints a handler shaped like mise's.
# HOMEBREW_REPOSITORY gives macOS a Homebrew handler to wrap; Ubuntu defines its own.
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
