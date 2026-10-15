#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On macOS, the ghostty step copies the config and reloads running Ghostty windows with SIGUSR2
# only when the config changed, and carries on when Ghostty isn't running. It installs nothing
# there. On Ubuntu, it installs the snap when missing; test-step-failures.sh covers its failures.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ghostty/install.sh
is_macos() { true; }
is_ubuntu() { false; }
config="$HOME/.config/ghostty/config.ghostty"

# A new config: copied, and Ghostty reloads it
stub pkill
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Reloaded Ghostty config."
assert_eq "" "$(cmp "$REPO_DIR/ghostty/config.ghostty" "$config" 2>&1)" "ghostty config copied"
assert_eq "pkill -USR2 -x ghostty" "$(cat "$STUB_LOG")" "commands run for a new config"

# Unchanged: no signal
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Reload"
assert_eq "" "$(cat "$STUB_LOG")" "commands run for an unchanged config"

# Changed while Ghostty isn't running: pkill finds no process, and the step still succeeds
echo "# an edit" >> "$config"
stub pkill 'exit 1'
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Ghostty is not running; skipping reload."
assert_eq "pkill -USR2 -x ghostty" "$(cat "$STUB_LOG")" "commands run with Ghostty not running"

# --- Ubuntu: the snap is installed when missing ---
is_macos() { false; }
is_ubuntu() { true; }
stub pkill 'exit 1'
stub snap 'exit 1'
export DOTFILES_ASSUME_YES=1
stub sudo
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo snap install ghostty --classic"
unset DOTFILES_ASSUME_YES
test_done
