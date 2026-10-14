#!/bin/bash
set -euo pipefail

# Reloading tmux.conf (prefix+r) leaves its array options as one load sets them, instead of
# appending another copy of each entry. Runs a tmux server on the sandbox's TMUX_TMPDIR.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v tmux &>/dev/null || skip "tmux isn't installed"

CONF="$REPO_DIR/tmux/tmux.conf"
arrays() {
    tmux show -s terminal-overrides
    tmux show -s terminal-features
    tmux show -g update-environment
}

tmux -f /dev/null new-session -d -s test
# tpm isn't in the sandbox, so the run line at the end fails; the rest still loads
tmux source-file "$CONF" &> /dev/null || true
once="$(arrays)"
assert_contains "$once" "xterm-ghostty:RGB:extkeys" "arrays after one load"
assert_contains "$once" "TERM_PROGRAM_VERSION" "arrays after one load"
for _ in 1 2; do
    tmux source-file "$CONF" &> /dev/null || true
done
assert_eq "$once" "$(arrays)" "arrays after three loads"
test_done
