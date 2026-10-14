#!/bin/bash
set -euo pipefail

# Killing the session a client is on, such as with prefix+X, moves the client to another session
# instead of detaching it (detach-on-destroy off). An outer tmux server's pane holds the client.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v tmux &> /dev/null || skip "tmux isn't installed"

tmux -f /dev/null new-session -d -s one
tmux new-session -d -s two
# tpm isn't in the sandbox, so the run line at the end fails; the rest still loads
tmux source-file "$REPO_DIR/tmux/tmux.conf" &> /dev/null || true
tmux -L outer -f /dev/null new-session -d -s outer -x 100 -y 30 "env -u TMUX tmux attach -t one"
for _ in $(seq 50); do
    [ -z "$(tmux list-clients)" ] || break
    sleep 0.1
done
assert_eq one "$(tmux list-clients -F '#{client_session}')" "the client's session"
tmux kill-session -t one
assert_eq two "$(tmux list-clients -F '#{client_session}')" "the client's session after killing its own"
tmux -L outer kill-server &> /dev/null || true
test_done
