#!/bin/bash
set -euo pipefail

# zsh/hooks.zsh's preexec hook copies the outer terminal's TERM_PROGRAM and TERM_PROGRAM_VERSION,
# and the SSH session's SSH_USER_AUTH, from tmux into the shell, and unsets one the attaching client
# didn't set. With tmux.conf's <socket>.attached marker, it asks tmux only on a pane's first command
# and after each attach, which writes the marker a new value; without it, before every command.
# Outside tmux it does nothing. tmux is stubbed, apart from the tmux.conf hook check, where a real
# tmux server on the sandbox's TMUX_TMPDIR runs tmux.conf's hooks. zsh/title.zsh's hooks set the
# terminal's title.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# The real tmux, for the tmux.conf hook check, before the stub below hides it
REAL_TMUX="$(command -v tmux || true)"
setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
SOCKET="$SANDBOX/tmux/default"
export TMUX_ENV="$SANDBOX/tmux-env"
stub tmux '[ "$1" != show-environment ] || cat "$TMUX_ENV"'

# Run the hook once per argument, after running that argument as a shell command, in one zsh that
# starts with TERM_PROGRAM=tmux, printing TERM_PROGRAM and TERM_PROGRAM_VERSION after each run
hook() {
    local script='source "$1/zsh/hooks.zsh"; shift
for cmd in "$@"; do
    eval "$cmd"
    _tmux_outer_terminal_preexec
    print -r -- "${TERM_PROGRAM-unset} ${TERM_PROGRAM_VERSION-unset}"
done'
    TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.5 zsh -f -c "$script" zsh "$REPO_DIR" "$@"
}

tmux_calls() {
    grep -c '^tmux show-environment' "$STUB_LOG" || true
}

printf '%s\n' TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.2.0 OTHER=x > "$TMUX_ENV"

# Outside tmux: nothing changes, and tmux isn't asked
unset TMUX
assert_eq "tmux 3.5" "$(hook :)" "variables outside tmux"
assert_eq 0 "$(tmux_calls)" "tmux calls outside tmux"

# No marker: tmux is asked before every command
export TMUX="$SOCKET,1234,0"
: > "$STUB_LOG"
assert_eq "ghostty 1.2.0
ghostty 1.2.0" "$(hook : :)" "variables without the marker"
assert_eq 2 "$(tmux_calls)" "tmux calls without the marker"

# With the marker: tmux is asked on the first command and after the marker's content changes, not
# between. An outer terminal that didn't send TERM_PROGRAM_VERSION leaves it unset.
echo 100 > "$SOCKET.attached"
: > "$STUB_LOG"
output="$(hook : \
    'printf "%s\n" TERM_PROGRAM=WezTerm -TERM_PROGRAM_VERSION > "$TMUX_ENV"' \
    'echo 101 > "${TMUX%%,*}.attached"')"
assert_eq "ghostty 1.2.0
ghostty 1.2.0
WezTerm unset" "$output" "variables with the marker"
assert_eq 2 "$(tmux_calls)" "tmux calls with the marker"

# Two attaches within one second, which leave the marker's mtime the same, each re-read the
# environment
printf '%s\n' TERM_PROGRAM=ghostty > "$TMUX_ENV"
echo 200 > "$SOCKET.attached"
touch -t 202601010000 "$SOCKET.attached"
: > "$STUB_LOG"
output="$(hook : \
    'echo TERM_PROGRAM=WezTerm > "$TMUX_ENV"; echo 201 > "${TMUX%%,*}.attached"; touch -t 202601010000 "${TMUX%%,*}.attached"' \
    'echo TERM_PROGRAM=kitty > "$TMUX_ENV"; echo 202 > "${TMUX%%,*}.attached"; touch -t 202601010000 "${TMUX%%,*}.attached"')"
assert_eq "ghostty 3.5
WezTerm 3.5
kitty 3.5" "$output" "variables after two attaches in one second"
assert_eq 3 "$(tmux_calls)" "tmux calls after two attaches in one second"

# An outer terminal that sent no TERM_PROGRAM leaves neither set
printf '%s\n' -TERM_PROGRAM -TERM_PROGRAM_VERSION > "$TMUX_ENV"
assert_eq "unset unset" "$(hook :)" "variables when the outer terminal set neither"

# SSH_USER_AUTH, which the ubuntu step reads to prove a key login, comes through the same way:
# exported when the attaching SSH session has it, and unset when it doesn't
auth_after_hook() {
    SSH_USER_AUTH=/run/old zsh -f -c 'source "$1/zsh/hooks.zsh"; _tmux_outer_terminal_preexec
print -r -- "${SSH_USER_AUTH-unset}"' zsh "$REPO_DIR"
}
rm -f "$SOCKET.attached"
printf '%s\n' TERM_PROGRAM=ghostty SSH_USER_AUTH=/run/sshd/auth > "$TMUX_ENV"
assert_eq "/run/sshd/auth" "$(auth_after_hook)" "SSH_USER_AUTH from an SSH attach"
printf '%s\n' TERM_PROGRAM=ghostty -SSH_USER_AUTH > "$TMUX_ENV"
assert_eq "unset" "$(auth_after_hook)" "SSH_USER_AUTH from a local attach"

# tmux.conf's client-attached and client-session-changed hooks write a new value to the marker. A
# control-mode client (-C) attaches without a terminal. tpm isn't in the sandbox, so the run line at
# the end of tmux.conf fails; the rest still loads.
if [ -z "$REAL_TMUX" ]; then
    skip_rest "the tmux hook check: tmux isn't installed"
else
    unset TMUX
    rtmux() { "$REAL_TMUX" -L hooks "$@"; }
    marker="$SANDBOX/tmux/tmux-$(id -u)/hooks.attached"
    # Wait up to five seconds for the marker to hold a value other than the one given, which
    # run-shell -b writes in the background
    wait_marker() {
        local i
        for i in $(seq 50); do
            [ -s "$marker" ] && [ "$(cat "$marker")" != "$1" ] && return 0
            sleep 0.1
        done
        return 1
    }
    # Panes run sleep, not a shell, which could write its history to $HOME as the test cleans up
    rtmux -f "$REPO_DIR/tmux/tmux.conf" new-session -d -s one 'sleep 60' 2> /dev/null || true
    rtmux new-session -d -s two 'sleep 60'
    assert_contains "$(rtmux show-options -g update-environment)" "SSH_USER_AUTH" "update-environment"
    [ ! -e "$marker" ] || fail "the marker exists before any client attached"
    # The client stays attached while its stdin, a sleep, stays open. Not a pipe from sleep, which
    # the wait below would wait for.
    rtmux -C attach -t one < <(sleep 10) > /dev/null &
    client_pid=$!
    wait_marker "" || fail "attaching a client didn't write $marker"
    attached="$(cat "$marker")"
    rtmux switch-client -c "$(rtmux list-clients -F '#{client_name}' | head -1)" -t two
    wait_marker "$attached" || fail "switching the client's session didn't write a new value to $marker"
    kill "$client_pid" 2> /dev/null || true
    rtmux kill-server 2> /dev/null || true
    wait "$client_pid" 2> /dev/null || true
fi
# zsh/title.zsh sets the title with OSC 2: the directory at the prompt, and the command line, with
# its control characters as spaces, while it runs, unless it starts with a space
mkdir -p "$HOME/proj"
title_script='source "$1/zsh/title.zsh"; cd ~/proj; _title_precmd; _title_preexec "$2" "$2"'
assert_eq "$(printf '\033]2;~/proj\a\033]2;echo a  b\a')" \
    "$(TERM=xterm-256color zsh -f -c "$title_script" zsh "$REPO_DIR" $'echo a\n b')" "the titles"
# A command with a leading space, which history leaves out, keeps the prompt's title
assert_eq "$(printf '\033]2;~/proj\a')" \
    "$(TERM=xterm-256color zsh -f -c "$title_script" zsh "$REPO_DIR" ' export TOKEN=secret')" "a hidden command's title"
test_done
