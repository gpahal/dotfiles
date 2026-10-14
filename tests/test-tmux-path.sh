#!/bin/bash
set -euo pipefail

# tmux.conf puts Homebrew's Linux dirs on the global PATH when they exist, so a tmux server
# started without them (continuum's systemd unit at boot) still finds Homebrew's tools, in panes
# and in run jobs such as tpm. Starts a server with only /usr/bin and /bin on PATH, and a stand-in
# tpm that records the PATH its run job got. The dirs exist on Ubuntu with Homebrew, including
# CI's runners; elsewhere the test checks that PATH is left alone.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v tmux &>/dev/null || skip "tmux isn't installed"

TMUX_BIN="$(command -v tmux)"
CONF="$REPO_DIR/tmux/tmux.conf"
BREW_DIRS=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin
mkdir -p "$HOME/.tmux/plugins/tpm"
printf '%s\n' '#!/bin/sh' 'echo "$PATH" > "$HOME/tpm-path"' > "$HOME/.tmux/plugins/tpm/tpm"
chmod +x "$HOME/.tmux/plugins/tpm/tpm"

# Loaded with source-file, not -f, which would hold the config's errors back until a client
# attaches; this way tmux prints them and fails
run env -i PATH=/usr/bin:/bin HOME="$HOME" TMUX_TMPDIR="$TMUX_TMPDIR" \
    "$TMUX_BIN" -f /dev/null new-session -d -s test \; source-file "$CONF"
assert_eq 0 "$RUN_STATUS" "loading tmux.conf"
assert_eq "" "$RUN_OUTPUT" "config errors"
global="$(tmux show-environment -g PATH)"
if [ -d /home/linuxbrew/.linuxbrew/bin ]; then
    assert_eq "PATH=$BREW_DIRS:/usr/bin:/bin" "$global" "global PATH"
    assert_eq "$BREW_DIRS:/usr/bin:/bin" "$(cat "$HOME/tpm-path")" "PATH in tpm's run job"
else
    assert_eq "PATH=/usr/bin:/bin" "$global" "global PATH without Homebrew's Linux dirs"
fi

# Reloading (prefix+r) doesn't add the dirs again
tmux source-file "$CONF"
tmux source-file "$CONF"
assert_eq "$global" "$(tmux show-environment -g PATH)" "global PATH after two reloads"
test_done
