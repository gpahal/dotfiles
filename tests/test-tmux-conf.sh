#!/bin/bash
set -euo pipefail
# serial

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v tmux &>/dev/null || skip "tmux isn't installed"

TMUX_BIN="$(command -v tmux)"
CONF="$REPO_DIR/tmux/tmux.conf"
mkdir -p "$HOME/.tmux/plugins/tpm"
printf '%s\n' '#!/bin/sh' > "$HOME/.tmux/plugins/tpm/tpm"
chmod +x "$HOME/.tmux/plugins/tpm/tpm"

# -f would hold config errors back until a client attaches; source-file prints them and fails
run env -i PATH=/usr/bin:/bin HOME="$HOME" TMUX_TMPDIR="$TMUX_TMPDIR" \
    "$TMUX_BIN" -f /dev/null new-session -d -s one \; source-file "$CONF"
assert_eq 0 "$RUN_STATUS" "loading tmux.conf"
assert_eq "" "$RUN_OUTPUT" "config errors"
assert_eq "PATH=/usr/bin:/bin" "$(tmux show-environment -g PATH)" "global PATH"
assert_eq all "$(tmux show-options -gv allow-passthrough)" "allow-passthrough"

arrays() {
    tmux show -s terminal-overrides
    tmux show -s terminal-features
    tmux show -g update-environment
}
once="$(arrays)"
assert_contains "$once" "xterm-ghostty:RGB:extkeys" "arrays after one load"
assert_contains "$once" "TERM_PROGRAM_VERSION" "arrays after one load"
for _ in 1 2; do
    tmux source-file "$CONF"
done
assert_eq "$once" "$(arrays)" "arrays after three loads"

tmux new-session -d -s two
tmux -L outer -f /dev/null new-session -d -s outer -x 100 -y 30 \
    "env -u TMUX TERM=tmux-256color tmux attach -t one"
for _ in $(seq 50); do
    [ -z "$(tmux list-clients)" ] || break
    sleep 0.1
done
assert_eq tmux-256color "$(tmux list-clients -F '#{client_termname}')" "the nested client's TERM"
assert_contains "$(tmux show-messages -T)" "setrgbf: (string)" "the nested client's capabilities"
assert_eq one "$(tmux list-clients -F '#{client_session}')" "the client's session"
tmux kill-session -t one
assert_eq two "$(tmux list-clients -F '#{client_session}')" "the client's session after killing its own"
tmux -L outer kill-server &> /dev/null || true
test_done
