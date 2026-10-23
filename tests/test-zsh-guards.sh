#!/bin/bash

# Shells a tool reads (T3 Code's PATH probe, Claude Code's snapshot) get no reminders or options.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v zsh &>/dev/null || skip "zsh isn't installed"
# compaudit, from the system zshrc's compinit, trusts dirs your own group can write, as Ubuntu's
# umask 002 makes them
stub getent "$(printf 'echo %q' "$(id -gn):x:$(id -g):")"
# This test may itself run under Claude Code
unset CLAUDECODE
export ZDOTDIR="$SANDBOX/zdotdir"
mkdir -p "$ZDOTDIR"
for file in options reminders; do
    echo "source '$REPO_DIR/zsh/$file.zsh'"
done > "$ZDOTDIR/.zshrc"

PROBE='echo probed; setopt | grep -xE "nocaseglob|correct|rcexpandparam|autocd" | sed "s/^/opt=/"; true'

reminders() {
    echo "every time" > "$HOME/.remind"
    echo "just once" > "$HOME/.remind-oneshot"
}

# The PATH probe: stdout is a pipe
reminders
output="$(zsh -ilc "$PROBE" < /dev/null | cat)"
assert_not_contains "$output" "every time" "probe output"
assert_not_contains "$output" "just once" "probe output"
[ -f "$HOME/.remind-oneshot" ] || fail "the probe removed ~/.remind-oneshot"
assert_contains "$output" "probed" "probe output"
assert_not_contains "$output" "opt=" "probe output"

# Claude Code's snapshot runs `zsh -c -l`, with CLAUDECODE=1 and stdout on a pipe
output="$(CLAUDECODE=1 zsh -c -l "source '$ZDOTDIR/.zshrc' < /dev/null; $PROBE" < /dev/null)"
assert_not_contains "$output" "opt=" "snapshot output"
[ -f "$HOME/.remind-oneshot" ] || fail "the snapshot removed ~/.remind-oneshot"

in_terminal_available || skip "script isn't installed, so the terminal checks can't run"

output="$(CLAUDECODE=1 in_terminal zsh -ilc "$PROBE")"
assert_not_contains "$output" "just once" "output under CLAUDECODE"
assert_not_contains "$output" "opt=" "output under CLAUDECODE"
[ -f "$HOME/.remind-oneshot" ] || fail "a shell under CLAUDECODE removed ~/.remind-oneshot"

output="$(in_terminal zsh -ilc "$PROBE")"
assert_contains "$output" "every time" "terminal output"
assert_contains "$output" "just once" "terminal output"
[ ! -f "$HOME/.remind-oneshot" ] || fail "a terminal shell left ~/.remind-oneshot"
assert_eq "$(printf 'opt=%s\n' autocd correct nocaseglob rcexpandparam)" "$(grep '^opt=' <<< "$output" | sort)" \
    "options in a terminal"
test_done
