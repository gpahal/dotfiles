#!/bin/bash
set -euo pipefail

# tmux.conf gives a client whose TERM is tmux-256color, such as tmux nested in a tmux pane over
# SSH, the RGB feature (setrgbf and setrgbb), so true color reaches the outer tmux. It also lets
# passthrough sequences, such as notifications, out of panes you can't see. Runs two tmux servers
# on the sandbox's TMUX_TMPDIR: the outer one's pane attaches a client to the inner one.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v tmux &> /dev/null || skip "tmux isn't installed"

tmux -f /dev/null new-session -d -s inner
# tpm isn't in the sandbox, so the run line at the end fails; the rest still loads
tmux source-file "$REPO_DIR/tmux/tmux.conf" &> /dev/null || true
assert_eq all "$(tmux show-options -gv allow-passthrough)" "allow-passthrough"
tmux -L outer -f /dev/null new-session -d -s outer -x 100 -y 30 \
    "env -u TMUX TERM=tmux-256color tmux attach -t inner"
for _ in $(seq 50); do
    [ -z "$(tmux list-clients)" ] || break
    sleep 0.1
done
assert_eq tmux-256color "$(tmux list-clients -F '#{client_termname}')" "the nested client's TERM"
assert_contains "$(tmux show-messages -T)" "setrgbf: (string)" "the nested client's capabilities"
tmux -L outer kill-server &> /dev/null || true
test_done
