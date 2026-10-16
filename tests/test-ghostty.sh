#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On macOS, the ghostty step copies the config and reloads running Ghostty windows with SIGUSR2
# only when the config changed, and carries on when Ghostty isn't running. Ghostty loads the files
# in ~/Library/Application Support/com.mitchellh.ghostty after the repo's config.ghostty, so status
# flags one that sets something the repo's config sets, and says nothing of one that only adds
# settings. Ubuntu has no Application Support. test-step-failures.sh covers Ubuntu's snap install.

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

# --- Application Support files ---
support="$HOME/Library/Application Support/com.mitchellh.ghostty"
mkdir -p "$support"
run status
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty" "Ghostty status with no other config"

# A setting the repo's config has overrides it. A keybind overrides only the same trigger.
printf 'keybind = super+shift+equal=increase_font_size:1\nfont-size = 20\n' > "$support/config"
printf 'keybind = super+k=clear_screen\nwindow-save-state = always\n' > "$support/config.ghostty"
run status
assert_contains "$RUN_OUTPUT" "missing    ~/Library/Application Support/com.mitchellh.ghostty/config: Ghostty loads it after config.ghostty, so it overrides the repo's font-size, keybind super+shift+equal; merge it into the repo's config or remove it"
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty/config.ghostty" "a file that only adds settings"
stub snap 'exit 1'
is_macos() { false; }
is_ubuntu() { true; }
run status
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty"
test_done
