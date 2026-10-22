#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script stream-deck/install.sh
as_os macos
src="$REPO_DIR/stream-deck/$PLUGIN"

mkdir -p "$SANDBOX/repo/stream-deck/$PLUGIN/bin"
touch "$SANDBOX/repo/stream-deck/$PLUGIN/"{manifest.json,.DS_Store,bin/open-in,bin/.DS_Store}
assert_eq "bin/open-in
manifest.json" "$(DOTFILES_DIR="$SANDBOX/repo" plugin_file_list | LC_ALL=C sort)" "plugin_file_list"

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

: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Restart"
assert_eq "" "$(cat "$STUB_LOG")" "commands run for an unchanged plugin"

# Stale files go, with folders left empty, but nothing outside the plugin
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

echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "plugin.js differs from the repo's"
stub pkill 'exit 1'
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Stream Deck isn't running; it loads the plugin when it starts."
assert_eq "pkill -x Stream Deck" "$(cat "$STUB_LOG")" "commands run with Stream Deck not running"
cmp -s "$src/plugin.js" "$PLUGIN_DIR/plugin.js" || fail "plugin.js wasn't restored"

assert_not_contains "$RUN_OUTPUT" "Backed up"
[ ! -e "$PLUGIN_DIR/plugin.js.bak" ] || fail "the step backed up the edit"
assert_exit 0 status

# open fails with -600 just after Stream Deck quits
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub pkill
stub sleep
stub open '[ -f "$SANDBOX/opened-once" ] && exit 0; touch "$SANDBOX/opened-once"; exit 1'
export SANDBOX
: > "$STUB_LOG"
assert_exit 0 main --no-backup
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin."
assert_eq 2 "$(grep -c '^open ' "$STUB_LOG")" "tries to reopen Stream Deck"

echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub open 'exit 1'
assert_exit 1 main --no-backup
assert_contains "$RUN_OUTPUT" "Couldn't reopen Stream Deck."

echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub pgrep
stub open
: > "$STUB_LOG"
assert_exit 1 main --no-backup
assert_contains "$RUN_OUTPUT" "Stream Deck didn't quit; quit and reopen it to load the plugin"
assert_not_contains "$RUN_OUTPUT" "Restarted"
assert_file_not_contains "$STUB_LOG" "open -g"
stub pgrep 'exit 1'

if command -v jq &> /dev/null; then
    actions="$(jq -r '.Actions[].UUID' "$src/manifest.json" | tr '\n' ' ')"
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

# The committed profile must match a fresh build-profile.sh run byte for byte
if command -v zip &> /dev/null && command -v jq &> /dev/null; then
    profile_src="$REPO_DIR/stream-deck/profile"
    assert_exit 0 bash "$REPO_DIR/stream-deck/build-profile.sh" "$SANDBOX/System.streamDeckProfile"
    cmp -s "$src/profiles/System.streamDeckProfile" "$SANDBOX/System.streamDeckProfile" ||
        fail "the System profile is out of date; run stream-deck/build-profile.sh"
    # A relative path is the caller's, though zip runs elsewhere
    mkdir -p "$SANDBOX/cwd"
    echo stale > "$SANDBOX/cwd/rel.streamDeckProfile"
    # shellcheck disable=SC2016 # the inner shell expands them
    assert_exit 0 bash -c 'cd "$1" && bash "$2" rel.streamDeckProfile' _ "$SANDBOX/cwd" "$REPO_DIR/stream-deck/build-profile.sh"
    cmp -s "$SANDBOX/System.streamDeckProfile" "$SANDBOX/cwd/rel.streamDeckProfile" ||
        fail "build-profile.sh with a relative path didn't build there"
    for action in $(cat "$profile_src"/*.sdProfile/Profiles/*/manifest.json | jq -r '.Controllers[].Actions // {} | .[].UUID'); do
        jq -e --arg uuid "$action" '.Actions | any(.UUID == $uuid)' "$src/manifest.json" > /dev/null ||
            fail "the System profile has $action, which the manifest lacks"
    done
else
    skip_rest "the profile checks: zip or jq isn't installed"
fi
test_done
