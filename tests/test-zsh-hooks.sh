#!/bin/bash
set -euo pipefail
# serial

# zsh/hooks.zsh takes the outer terminal and SSH login from tmux at attach, and title.zsh's titles.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REAL_TMUX="$(command -v tmux || true)"
setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
SOCKET="$SANDBOX/tmux/default"
export TMUX_ENV="$SANDBOX/tmux-env"
stub tmux '[ "$1" != show-environment ] || cat "$TMUX_ENV"'

# Runs each argument, then the hook, in one zsh, printing TERM_PROGRAM and its version
hook() {
    local script='autoload -U add-zsh-hook; source "$1/zsh/hooks.zsh"; shift
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

unset TMUX
assert_eq "tmux 3.5" "$(hook :)" "variables outside tmux"
assert_eq 0 "$(tmux_calls)" "tmux calls outside tmux"

export TMUX="$SOCKET,1234,0"
: > "$STUB_LOG"
assert_eq "ghostty 1.2.0
ghostty 1.2.0" "$(hook : :)" "variables without the marker"
assert_eq 2 "$(tmux_calls)" "tmux calls without the marker"

# With the marker, tmux is asked only on the first command and after the marker changes
echo 100 > "$SOCKET.attached"
: > "$STUB_LOG"
output="$(hook : \
    'printf "%s\n" TERM_PROGRAM=WezTerm -TERM_PROGRAM_VERSION > "$TMUX_ENV"' \
    'echo 101 > "${TMUX%%,*}.attached"')"
assert_eq "ghostty 1.2.0
ghostty 1.2.0
WezTerm unset" "$output" "variables with the marker"
assert_eq 2 "$(tmux_calls)" "tmux calls with the marker"

# The ubuntu step reads SSH_USER_AUTH to prove a key login
auth_after_hook() {
    SSH_USER_AUTH=/run/old zsh -f -c 'autoload -U add-zsh-hook; source "$1/zsh/hooks.zsh"; _tmux_outer_terminal_preexec
print -r -- "${SSH_USER_AUTH-unset}"' zsh "$REPO_DIR"
}
rm -f "$SOCKET.attached"
printf '%s\n' TERM_PROGRAM=ghostty SSH_USER_AUTH=/run/sshd/auth > "$TMUX_ENV"
assert_eq "/run/sshd/auth" "$(auth_after_hook)" "SSH_USER_AUTH from an SSH attach"
printf '%s\n' TERM_PROGRAM=ghostty -SSH_USER_AUTH > "$TMUX_ENV"
assert_eq "unset" "$(auth_after_hook)" "SSH_USER_AUTH from a local attach"

# tpm isn't in the sandbox, so tmux.conf's last run line fails; the rest still loads.
if [ -z "$REAL_TMUX" ]; then
    skip_rest "the tmux hook check: tmux isn't installed"
else
    unset TMUX
    rtmux() { "$REAL_TMUX" -L hooks "$@"; }
    marker="$SANDBOX/tmux/tmux-$(id -u)/hooks.attached"
    # run-shell -b writes the marker in the background
    marker_changed_from() {
        [ -s "$marker" ] && [ "$(cat "$marker")" != "$1" ]
    }
    # Panes run sleep: a shell could write its history to $HOME during cleanup
    rtmux -f "$REPO_DIR/tmux/tmux.conf" new-session -d -s one 'sleep 60' 2> /dev/null || true
    rtmux new-session -d -s two 'sleep 60'
    assert_contains "$(rtmux show-options -g update-environment)" "SSH_USER_AUTH" "update-environment"
    [ ! -e "$marker" ] || fail "the marker exists before any client attached"
    # Not a pipe from sleep, which the wait below would wait for
    rtmux -C attach -t one < <(sleep 10) > /dev/null &
    client_pid=$!
    wait_for marker_changed_from "" || fail "attaching a client didn't write $marker"
    attached="$(cat "$marker")"
    rtmux switch-client -c "$(rtmux list-clients -F '#{client_name}' | head -1)" -t two
    wait_for marker_changed_from "$attached" || fail "switching the client's session didn't write a new value to $marker"
    kill "$client_pid" 2> /dev/null || true
    rtmux kill-server 2> /dev/null || true
    wait "$client_pid" 2> /dev/null || true
fi
mkdir -p "$HOME/proj"
title_script='OSTYPE=$3; autoload -U add-zsh-hook; source "$1/zsh/title.zsh"; cd ~/proj; _title_precmd; _title_preexec "$2" "$2"'
assert_eq "$(printf '\033]2;~/proj\a\033]2;echo a  b\a')" \
    "$(TERM=xterm-256color zsh -f -c "$title_script" zsh "$REPO_DIR" $'echo a\n b' darwin25.0)" "the titles on macOS"
# On Linux the folder follows the command, for the Stream Deck's open-in; a % stays literal
assert_eq "$(printf '\033]2;~/proj\a\033]2;echo %%~ b — ~/proj\a')" \
    "$(TERM=xterm-256color zsh -f -c "$title_script" zsh "$REPO_DIR" 'echo %~ b' linux-gnu)" "the titles on Linux"
# A leading space, which history skips, keeps the prompt's title
assert_eq "$(printf '\033]2;~/proj\a')" \
    "$(TERM=xterm-256color zsh -f -c "$title_script" zsh "$REPO_DIR" ' export TOKEN=secret' linux-gnu)" "a hidden command's title"
test_done
