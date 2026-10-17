#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On macOS, the stream-deck step copies the plugin and restarts a running Stream Deck only when
# the plugin changed, trying again when it doesn't reopen at first, and carries on when Stream
# Deck isn't running. The step lists every file in
# the plugin, and each of the manifest's actions is a target plugin.js maps to open-in or open-app,
# a stat key stats.js draws, or Back. The bundled System profile is built from stream-deck/profile
# and holds only the plugin's actions.

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

# open fails with -600 just after Stream Deck quits: the step tries again
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub pkill
stub sleep
# shellcheck disable=SC2016 # expanded when the stub runs
stub open '[ -f "$SANDBOX/opened-once" ] && exit 0; touch "$SANDBOX/opened-once"; exit 1'
export SANDBOX
: > "$STUB_LOG"
assert_exit 0 main --no-backup
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin."
assert_eq 2 "$(grep -c '^open ' "$STUB_LOG")" "tries to reopen Stream Deck"

# Stream Deck doesn't reopen: the step fails
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub open 'exit 1'
assert_exit 1 main --no-backup
assert_contains "$RUN_OUTPUT" "Couldn't reopen Stream Deck."

# Each of the manifest's actions is a script's target, a stat key, or Back, and their images are in
# the plugin
if command -v jq &> /dev/null; then
    actions="$(jq -r '.Actions[].UUID' "$src/manifest.json" | tr '\n' ' ')"
    assert_eq "com.gpahal.dotfiles.finder com.gpahal.dotfiles.editor com.gpahal.dotfiles.terminal com.gpahal.dotfiles.claude com.gpahal.dotfiles.chrome com.gpahal.dotfiles.chrome-tab com.gpahal.dotfiles.overview com.gpahal.dotfiles.cpu com.gpahal.dotfiles.memory com.gpahal.dotfiles.swap com.gpahal.dotfiles.top com.gpahal.dotfiles.gpu com.gpahal.dotfiles.temperature com.gpahal.dotfiles.power com.gpahal.dotfiles.disk com.gpahal.dotfiles.network com.gpahal.dotfiles.activity-monitor com.gpahal.dotfiles.back " \
        "$actions" "the manifest's actions"
    for action in $actions; do
        target="${action##*.}"
        [ "$target" == back ] ||
            grep -qE "^  \"?$target\"?: \"open-(in|app)\",$" "$src/plugin.js" ||
            grep -qE "^  \"?$target\"?: \[" "$src/stats.js" ||
            fail "neither plugin.js nor stats.js handles $target"
    done
    for image in $(jq -r '.Icon, .CategoryIcon, (.Actions[] | .Icon, .States[].Image)' "$src/manifest.json"); do
        [ -f "$src/$image.svg" ] || [ -f "$src/$image.png" ] || fail "the manifest names $image, which isn't in the plugin"
    done
    for profile in $(jq -r '.Profiles[].Name' "$src/manifest.json"); do
        [ -f "$src/$profile.streamDeckProfile" ] || fail "the manifest names $profile, which isn't in the plugin"
    done
else
    skip_rest "the manifest checks: jq isn't installed"
fi

# The System profile's zip holds stream-deck/profile's files, so build-profile.sh ran after the
# last edit, and its keys are the plugin's actions
zip_file="$src/profiles/System.streamDeckProfile"
if command -v unzip &> /dev/null && command -v jq &> /dev/null; then
    profile_src="$REPO_DIR/stream-deck/profile"
    zipped="$(unzip -Z1 "$zip_file" | grep -v '/$' | LC_ALL=C sort)"
    sources="$(cd "$profile_src" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
    assert_eq "$sources" "$zipped" "the System profile's files; run stream-deck/build-profile.sh"
    for file in $sources; do
        [ "$(unzip -p "$zip_file" "$file")" == "$(cat "$profile_src/$file")" ] ||
            fail "the System profile's $file is out of date; run stream-deck/build-profile.sh"
    done
    for action in $(cat "$profile_src"/*.sdProfile/Profiles/*/manifest.json | jq -r '.Controllers[].Actions // {} | .[].UUID'); do
        jq -e --arg uuid "$action" '.Actions | any(.UUID == $uuid)' "$src/manifest.json" > /dev/null ||
            fail "the System profile has $action, which the manifest lacks"
    done
else
    skip_rest "the profile checks: unzip or jq isn't installed"
fi
test_done
