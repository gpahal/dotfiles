#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On macOS, the stream-deck step copies the plugin and restarts a running Stream Deck only when
# the plugin changed, and carries on when Stream Deck isn't running. On Ubuntu, it skips. The
# step lists every file in the plugin, and the manifest's actions match open-in's targets.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script stream-deck/install.sh
is_macos() { true; }
src="$REPO_DIR/stream-deck/$PLUGIN"

# Every file in the repo's plugin is installed
listed="$(tr -s ' ' '\n' <<< "$PLUGIN_FILES" | LC_ALL=C sort)"
found="$(cd "$src" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
assert_eq "$found" "$listed" "PLUGIN_FILES"

# A new plugin: copied, and the running Stream Deck restarts to load it
stub pkill
stub pgrep 'exit 1'
stub open
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin."
for file in $PLUGIN_FILES; do
    cmp -s "$src/$file" "$PLUGIN_DIR/$file" || fail "$file wasn't copied to $PLUGIN_DIR"
done
[ -x "$PLUGIN_DIR/bin/open-in" ] || fail "bin/open-in isn't executable"
assert_eq "pkill -x Stream Deck
pgrep -x Stream Deck
open -g -b com.elgato.StreamDeck" "$(cat "$STUB_LOG")" "commands run for a new plugin"
assert_exit 0 status
assert_not_contains "$RUN_OUTPUT" "missing"

# Unchanged: no restart
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Restart"
assert_eq "" "$(cat "$STUB_LOG")" "commands run for an unchanged plugin"

# Changed while Stream Deck isn't running: status reports the edit, and the step restores the
# file and still succeeds
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "plugin.js was edited since setup installed it"
stub pkill 'exit 1'
: > "$STUB_LOG"
assert_exit 0 main --no-backup
assert_contains "$RUN_OUTPUT" "Stream Deck isn't running; it loads the plugin when it starts."
assert_eq "pkill -x Stream Deck" "$(cat "$STUB_LOG")" "commands run with Stream Deck not running"
cmp -s "$src/plugin.js" "$PLUGIN_DIR/plugin.js" || fail "plugin.js wasn't restored"

# Stream Deck doesn't reopen: the step fails
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub pkill
stub open 'exit 1'
assert_exit 1 main --no-backup
assert_contains "$RUN_OUTPUT" "Couldn't reopen Stream Deck."

# --- Ubuntu: nothing to do ---
is_macos() { false; }
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Stream Deck has no Linux app; skipping."
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    Stream Deck plugin"
assert_eq "" "$(cat "$STUB_LOG")" "commands run on Ubuntu"

# The manifest's actions are open-in's targets, and their images are in the plugin
if command -v jq &> /dev/null; then
    actions="$(jq -r '.Actions[].UUID' "$src/manifest.json" | tr '\n' ' ')"
    assert_eq "com.gpahal.dotfiles.finder com.gpahal.dotfiles.editor com.gpahal.dotfiles.terminal " \
        "$actions" "the manifest's actions"
    for image in $(jq -r '.Icon, .CategoryIcon, (.Actions[] | .Icon, .States[].Image)' "$src/manifest.json"); do
        [ -f "$src/$image.svg" ] || [ -f "$src/$image.png" ] || fail "the manifest names $image, which isn't in the plugin"
    done
else
    skip_rest "the manifest checks: jq isn't installed"
fi
test_done
