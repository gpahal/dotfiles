#!/bin/bash
set -euo pipefail

# Shells whose output a tool reads (T3 Code's `$SHELL -ilc` PATH probe, Claude Code's shell
# snapshot) don't print the reminders, use up the oneshot ones, or get the correct, nocaseglob,
# rcexpandparam, and autocd options. A shell in a terminal gets all of them. Runs zsh with a sandbox
# ZDOTDIR whose .zshrc sources the repo's files.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
# This test may itself run under Claude Code
unset CLAUDECODE
export ZDOTDIR="$SANDBOX/zdotdir"
mkdir -p "$ZDOTDIR"
for file in options reminders; do
    echo "source '$REPO_DIR/zsh/$file.zsh'"
done > "$ZDOTDIR/.zshrc"
# /etc/zprofile's path_helper puts the system's dirs, /opt/homebrew/bin among them on macOS, ahead
# of the stubs, so a sentinel the config ran would find the real command
# shellcheck disable=SC2016 # expanded by zsh
printf 'path=(%q $path)\n' "$STUB_DIR" > "$ZDOTDIR/.zprofile"
stub mise

# What the shell sets up, printed after any reminders, and the mise it finds
PROBE='echo probed; setopt | grep -xE "nocaseglob|correct|rcexpandparam|autocd" | sed "s/^/opt=/"
print -r -- "mise=$(whence -p mise)"; true'

reminders() {
    echo "every time" > "$HOME/.remind"
    echo "just once" > "$HOME/.remind-oneshot"
}

# Run an interactive login zsh in a pseudo-terminal, printing its output without carriage returns
in_terminal() {
    if [[ "$OSTYPE" == darwin* ]]; then
        script -q /dev/null "$@"
    else
        script -qec "$(printf '%q ' "$@")" /dev/null
    fi < /dev/null | tr -d '\r'
}

# The PATH probe: stdout is a pipe
reminders
output="$(zsh -ilc "$PROBE" < /dev/null | cat)"
assert_not_contains "$output" "every time" "probe output"
assert_not_contains "$output" "just once" "probe output"
[ -f "$HOME/.remind-oneshot" ] || fail "the probe removed ~/.remind-oneshot"
assert_contains "$output" "probed" "probe output"
assert_not_contains "$output" "opt=" "probe output"
assert_contains "$output" "mise=$STUB_DIR/mise" "the mise the probe finds"

# Claude Code's snapshot runs `zsh -c -l`, with CLAUDECODE=1 and stdout on a pipe
output="$(CLAUDECODE=1 zsh -c -l "source '$ZDOTDIR/.zshrc' < /dev/null; $PROBE" < /dev/null)"
assert_not_contains "$output" "opt=" "snapshot output"
[ -f "$HOME/.remind-oneshot" ] || fail "the snapshot removed ~/.remind-oneshot"

command -v script &>/dev/null || skip "script isn't installed, so the terminal checks can't run"

# CLAUDECODE alone keeps them out, even with a terminal
output="$(CLAUDECODE=1 in_terminal zsh -ilc "$PROBE")"
assert_not_contains "$output" "just once" "output under CLAUDECODE"
assert_not_contains "$output" "opt=" "output under CLAUDECODE"
[ -f "$HOME/.remind-oneshot" ] || fail "a shell under CLAUDECODE removed ~/.remind-oneshot"

# A terminal gets everything
output="$(in_terminal zsh -ilc "$PROBE")"
assert_contains "$output" "every time" "terminal output"
assert_contains "$output" "just once" "terminal output"
[ ! -f "$HOME/.remind-oneshot" ] || fail "a terminal shell left ~/.remind-oneshot"
assert_contains "$output" "opt=nocaseglob" "terminal output"
assert_contains "$output" "opt=correct" "terminal output"
assert_contains "$output" "opt=rcexpandparam" "terminal output"
assert_contains "$output" "opt=autocd" "terminal output"
assert_contains "$output" "mise=$STUB_DIR/mise" "the mise a terminal finds"
test_done
