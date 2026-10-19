#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On macOS, the stream-deck step copies the plugin, removes installed files the repo's plugin no
# longer has, and restarts a running Stream Deck only when the plugin changed, trying again when
# it doesn't reopen at first, carries on when Stream Deck isn't running, and fails when it doesn't
# quit. Each of the
# manifest's actions is a target of open-in, a stat key stats.js draws, or Back. The bundled
# System profile is built from stream-deck/profile and holds only the plugin's actions.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script stream-deck/install.sh
is_macos() { true; }
src="$REPO_DIR/stream-deck/$PLUGIN"

# The plugin's files, found in the repo, leave out a .DS_Store Finder leaves there
mkdir -p "$SANDBOX/repo/stream-deck/$PLUGIN/bin"
touch "$SANDBOX/repo/stream-deck/$PLUGIN/"{manifest.json,.DS_Store,bin/open-in,bin/.DS_Store}
assert_eq "bin/open-in
manifest.json" "$(DOTFILES_DIR="$SANDBOX/repo" plugin_file_list | LC_ALL=C sort)" "plugin_file_list"

# A new plugin: copied, and the running Stream Deck restarts to load it
stub pkill
stub pgrep 'exit 1'
stub open
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin."
while IFS= read -r file; do
    cmp -s "$src/$file" "$PLUGIN_DIR/$file" || fail "$file wasn't copied to $PLUGIN_DIR"
done < <(cd "$src" && find . -type f | sed 's|^\./||')
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

# Files the repo's plugin no longer has: status lists them, and the step removes them, and a
# folder that leaves empty, but nothing outside the plugin, then restarts Stream Deck
mkdir -p "$PLUGIN_DIR/old" "$PLUGIN_DIR/../other.sdPlugin"
touch "$PLUGIN_DIR/bin/open-app" "$PLUGIN_DIR/old/x.js" "$PLUGIN_DIR/../other.sdPlugin/x.js"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    bin/open-app in the installed plugin: the repo's plugin no longer has it"
assert_contains "$RUN_OUTPUT" "missing    old/x.js in the installed plugin"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Removed bin/open-app, which the repo's plugin no longer has"
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin."
[ ! -e "$PLUGIN_DIR/bin/open-app" ] && [ ! -e "$PLUGIN_DIR/old" ] || fail "the stale files weren't removed"
[ -f "$PLUGIN_DIR/../other.sdPlugin/x.js" ] || fail "a file outside the plugin was removed"
[ -f "$PLUGIN_DIR/bin/open-in" ] || fail "bin/open-in was removed"
assert_exit 0 status

# Changed while Stream Deck isn't running: status reports the edit, and the step restores the
# file and still succeeds
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "plugin.js differs from the repo's"
stub pkill 'exit 1'
: > "$STUB_LOG"
assert_exit 0 main --no-backup
assert_contains "$RUN_OUTPUT" "Stream Deck isn't running; it loads the plugin when it starts."
assert_eq "pkill -x Stream Deck" "$(cat "$STUB_LOG")" "commands run with Stream Deck not running"
cmp -s "$src/plugin.js" "$PLUGIN_DIR/plugin.js" || fail "plugin.js wasn't restored"

# An edit is replaced with no backup
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Backed up"
[ ! -e "$PLUGIN_DIR/plugin.js.bak" ] || fail "the step backed up the edit"
assert_exit 0 status

# open fails with -600 just after Stream Deck quits: the step tries again
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub pkill
stub sleep
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

# Stream Deck doesn't quit within the wait: the step fails without reopening it, rather than
# claiming a restart
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub pgrep
stub open
: > "$STUB_LOG"
assert_exit 1 main --no-backup
assert_contains "$RUN_OUTPUT" "Stream Deck didn't quit; quit and reopen it to load the plugin"
assert_not_contains "$RUN_OUTPUT" "Restarted"
assert_file_not_contains "$STUB_LOG" "open -g"
stub pgrep 'exit 1'

# Each of the manifest's actions is a script's target, a stat key, or Back, and their images are in
# the plugin
if command -v jq &> /dev/null; then
    actions="$(jq -r '.Actions[].UUID' "$src/manifest.json" | tr '\n' ' ')"
    assert_eq "com.gpahal.dotfiles.overview com.gpahal.dotfiles.editor com.gpahal.dotfiles.terminal com.gpahal.dotfiles.files com.gpahal.dotfiles.chrome com.gpahal.dotfiles.chrome-tab com.gpahal.dotfiles.gmail com.gpahal.dotfiles.t3-code com.gpahal.dotfiles.claude com.gpahal.dotfiles.cpu com.gpahal.dotfiles.memory com.gpahal.dotfiles.swap com.gpahal.dotfiles.top com.gpahal.dotfiles.gpu com.gpahal.dotfiles.temperature com.gpahal.dotfiles.power com.gpahal.dotfiles.disk com.gpahal.dotfiles.network com.gpahal.dotfiles.activity-monitor com.gpahal.dotfiles.back " \
        "$actions" "the manifest's actions"
    open_in_targets="|$(sed -n 's/^# Usage: open-in //p' "$src/bin/open-in")|"
    for action in $actions; do
        target="${action##*.}"
        [ "$target" == back ] || [[ "$open_in_targets" == *"|$target|"* ]] ||
            grep -qE "^  \"?$target\"?: \[" "$src/stats.js" ||
            fail "neither open-in nor stats.js handles $target"
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
