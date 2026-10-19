#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions
set -euo pipefail

# Ghostty loads Application Support files after config.ghostty, so overlapping settings are flagged

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ghostty/install.sh
as_os macos
config="$HOME/.config/ghostty/config.ghostty"

stub pkill
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Reloaded Ghostty config."
assert_eq "" "$(cmp "$REPO_DIR/ghostty/config.ghostty" "$config" 2>&1)" "ghostty config copied"
assert_eq "pkill -USR2 -x ghostty" "$(cat "$STUB_LOG")" "commands run for a new config"

: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Reload"
assert_eq "" "$(cat "$STUB_LOG")" "commands run for an unchanged config"

echo "# an edit" >> "$config"
stub pkill 'exit 1'
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Ghostty is not running; skipping reload."
assert_eq "pkill -USR2 -x ghostty" "$(cat "$STUB_LOG")" "commands run with Ghostty not running"

support="$HOME/Library/Application Support/com.mitchellh.ghostty"
mkdir -p "$support"
run status
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty" "Ghostty status with no other config"

# A keybind overrides only the same trigger
printf 'keybind = super+shift+equal=increase_font_size:1\nfont-size = 20\n' > "$support/config"
printf 'keybind = super+k=clear_screen\nwindow-save-state = always\n' > "$support/config.ghostty"
run status
assert_contains "$RUN_OUTPUT" "missing    ~/Library/Application Support/com.mitchellh.ghostty/config: Ghostty loads it after config.ghostty, so it overrides the repo's font-size, keybind super+shift+equal; merge it into the repo's config or remove it"
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty/config.ghostty" "a file that only adds settings"
stub snap 'exit 1'
as_os ubuntu
run status
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty"
test_done
