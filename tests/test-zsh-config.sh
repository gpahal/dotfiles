#!/bin/bash
set -euo pipefail

# The whole zsh config, as the zsh step installs it, loads in a terminal without printing to
# stderr, also with TERM=dumb. Checks what it sets up there: ^ isn't a glob operator, cat and tree
# stay the real commands, the eza aliases give --classify its value, _cached_init keys its cache on
# the init arguments, and mise's command-not-found handler wraps the config's. Uses the tools
# installed on this machine (starship, atuin, ...), each with the sandbox HOME, and stubs mise, bat,
# and eza.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
command -v script &>/dev/null || skip "script isn't installed"
# Under Claude Code, CLAUDECODE would turn off the terminal-only options and reminders
unset CLAUDECODE
stub dscl 'case "$*" in *UserShell*) echo "UserShell: /bin/zsh" ;; *) exit 1 ;; esac'
stub getent 'echo "$2:x:1000:1000::$HOME:/usr/bin/zsh"'
stub chsh 'exit 1'
assert_exit 0 bash "$REPO_DIR/zsh/install.sh"
stub brew 'exit 1'
# mise is a sentinel, and the config runs mise when it finds one on PATH
stub mise

WORK="$SANDBOX/work"
mkdir -p "$WORK"
ERR="$SANDBOX/stderr"

# Run commands in an interactive login zsh in a pseudo-terminal, from $WORK, printing its output
# without carriage returns. Its stderr goes to $ERR. Usage: in_terminal <TERM> <commands>
in_terminal() {
    local cmd
    # shellcheck disable=SC2016 # expanded by sh
    cmd="$(printf '%q ' /bin/sh -c 'cd "$1" && TERM=$2 exec zsh -lic "$3" 2> "$4"' sh "$WORK" "$@" "$ERR")"
    if [[ "$OSTYPE" == darwin* ]]; then
        script -q /dev/null /bin/sh -c "$cmd"
    else
        script -qec "$cmd" /dev/null
    fi < /dev/null | tr -d '\r'
}

for term in xterm-256color dumb; do
    output="$(in_terminal "$term" 'echo loaded')"
    assert_contains "$output" "loaded" "output with TERM=$term"
    assert_eq "" "$(cat "$ERR")" "stderr with TERM=$term"
done

# ^ is a plain character, so git's HEAD^ and main^ reach git as typed, even when files match the
# pattern ^ would make
touch "$WORK/main.go" "$WORK/main_test.go"
output="$(in_terminal xterm-256color 'print -r -- main^; [[ -o extendedglob ]] && echo extendedglob-on; true')"
assert_contains "$output" "main^" "main^ in a terminal"
assert_not_contains "$output" "extendedglob-on" "options in a terminal"
assert_eq "" "$(cat "$ERR")" "stderr from main^"

# cat and tree are the real commands. c and t are bat and eza, which are stubbed, since CI
# doesn't install them.
stub bat
stub eza
output="$(in_terminal xterm-256color 'for a in cat tree c t; do echo "$a=$(alias $a)"; done')"
assert_contains "$output" "cat=
" "aliases"
assert_contains "$output" "tree=
" "aliases"
assert_contains "$output" "c=c='bat -pp'" "aliases"
assert_contains "$output" "t=t='eza --tree -a -I .git'" "aliases"
# eza reads a bare -F as --classify [WHEN], so it would take a path after it as the WHEN
output="$(in_terminal xterm-256color 'for a in l la ll lla; do alias $a; done')"
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
# With -f, it regenerates when that file, such as the tool's config, changes, moves, or goes away,
# even to one older than the cache
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
touch -t 200101010000 "$SANDBOX/fakeinit.conf"
run_with_file "$SANDBOX/fakeinit.conf" "older -f file" 5
echo two > "$SANDBOX/other.conf"
touch -t 200001010000 "$SANDBOX/other.conf"
run_with_file "$SANDBOX/other.conf" "older -f file at another path" 6
rm "$SANDBOX/other.conf"
run_with_file "$SANDBOX/other.conf" "deleted -f file" 7
run_with_file "$SANDBOX/other.conf" "still deleted -f file" 7

# abspath prints a path made absolute, and no function hides coreutils' dir
mkdir -p "$SANDBOX/real" && ln -sfn "$SANDBOX/real" "$SANDBOX/link"
output="$(cd "$SANDBOX" && zsh -c "source '$HOME/.zsh/main.zsh'; abspath link; whence -w dir" 2>&1)" || true
assert_contains "$output" "$(cd -P "$SANDBOX/real" && pwd)" "abspath output"
assert_not_contains "$output" "dir: function" "whence -w dir"

# Atuin AI is off, so ? on an empty prompt types a ?
if command -v atuin &>/dev/null; then
    output="$(in_terminal xterm-256color "bindkey '?'")"
    assert_contains "$output" '"?" self-insert' "the ? binding"
fi

# mise's activation wraps the command-not-found handler already defined, so it must load after
# command-not-found.zsh, or that replaces mise's. The stub prints a handler shaped like mise's.
# HOMEBREW_REPOSITORY gives macOS a Homebrew handler to wrap; Ubuntu defines its own.
export HOMEBREW_PREFIX="$SANDBOX/brew" HOMEBREW_REPOSITORY="$SANDBOX/brew"
mkdir -p "$HOMEBREW_REPOSITORY/Library/Homebrew/command-not-found"
echo 'command_not_found_handler() { print "homebrew: $1"; return 127; }' \
    > "$HOMEBREW_REPOSITORY/Library/Homebrew/command-not-found/handler.sh"
# shellcheck disable=SC2016 # expanded by zsh
stub mise '[ "$*" != "activate zsh" ] || echo '\''
(( $+functions[command_not_found_handler] )) && functions[_command_not_found_handler]=$functions[command_not_found_handler]
command_not_found_handler() { print "mise: $1"; _command_not_found_handler "$@"; }'\'
output="$(zsh -c "source '$HOME/.zsh/main.zsh'; nosuchtool" 2>&1)" || true
assert_contains "$output" "mise: nosuchtool" "the handler left after loading"
assert_not_contains "$output" "_command_not_found_handler" "the handler mise wraps"
unset HOMEBREW_PREFIX HOMEBREW_REPOSITORY
test_done
