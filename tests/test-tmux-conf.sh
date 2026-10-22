#!/bin/bash
set -euo pipefail

# tmux.conf loads without errors, and reloading it doesn't grow its arrays.

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
test_done
