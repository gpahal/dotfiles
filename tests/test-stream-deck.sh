#!/bin/bash
set -euo pipefail

# The stream-deck step on macOS: the plugin, its stale files, and the profiles Stream Deck installs
# from it in a fake ProfilesV3, with stubs for pkill, pgrep, and open. Then the profile archives,
# which build-profile.sh must rebuild byte for byte.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"
load_script stream-deck/install.sh
as_os macos
src="$REPO_DIR/stream-deck/$PLUGIN"
layout="$src/layout.json"

mkdir -p "$SANDBOX/repo/stream-deck/$PLUGIN/bin"
touch "$SANDBOX/repo/stream-deck/$PLUGIN/"{manifest.json,manifest.json.bak,.DS_Store,bin/open-in,bin/.DS_Store}
assert_eq "bin/open-in
manifest.json
manifest.json.bak" "$(DOTFILES_DIR="$SANDBOX/repo" plugin_file_list | LC_ALL=C sort)" "plugin_file_list"

stub pkill
stub pgrep 'exit 1'
stub open
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin and its profiles."
while IFS= read -r file; do
    cmp -s "$src/$file" "$PLUGIN_DIR/$file" || fail "$file wasn't copied to $PLUGIN_DIR"
done < <(cd "$src" && find . -type f | sed 's|^\./||')
[ -x "$PLUGIN_DIR/bin/open-in" ] || fail "bin/open-in isn't executable"
assert_eq "pkill -x Stream Deck
pgrep -x Stream Deck
open -g -b com.elgato.StreamDeck" "$(cat "$STUB_LOG")" "commands run for a new plugin"
# Stream Deck installs the profiles itself
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Stream Deck's Main profile: Stream Deck installs it when it loads the plugin"
assert_contains "$RUN_OUTPUT" "missing    Stream Deck's System profile: press the key that opens it"
assert_not_contains "$RUN_OUTPUT" "differs"

: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Restart"
assert_eq "" "$(cat "$STUB_LOG")" "commands run for an unchanged plugin"

# Stale files go, with folders left empty, but nothing outside the plugin
# shellcheck disable=SC2088 # shown, not expanded
shown_plugin="~/Library/Application Support/com.elgato.StreamDeck/Plugins/$PLUGIN"
mkdir -p "$PLUGIN_DIR/old" "$PLUGIN_DIR/../other.sdPlugin"
touch "$PLUGIN_DIR/bin/old-tool" "$PLUGIN_DIR/old/x.js" "$PLUGIN_DIR/plugin.js.bak" "$PLUGIN_DIR/../other.sdPlugin/x.js"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $shown_plugin/bin/old-tool: the repo's plugin no longer has it; re-run the stream-deck step"
assert_contains "$RUN_OUTPUT" "missing    $shown_plugin/old/x.js"
assert_contains "$RUN_OUTPUT" "missing    $shown_plugin/plugin.js.bak"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Removed bin/old-tool, which the repo's plugin no longer has"
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin and its profiles."
[ ! -e "$PLUGIN_DIR/bin/old-tool" ] && [ ! -e "$PLUGIN_DIR/old" ] && [ ! -e "$PLUGIN_DIR/plugin.js.bak" ] ||
    fail "the stale files weren't removed"
[ -f "$PLUGIN_DIR/../other.sdPlugin/x.js" ] || fail "a file outside the plugin was removed"
[ -f "$PLUGIN_DIR/bin/open-in" ] || fail "bin/open-in was removed"
assert_exit 3 status
assert_not_contains "$RUN_OUTPUT" "no longer has it"

echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "plugin.js differs from the repo's"
stub pkill 'exit 1'
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Stream Deck isn't running; it loads the plugin and its profiles when it starts."
assert_eq "pkill -x Stream Deck" "$(cat "$STUB_LOG")" "commands run with Stream Deck not running"
cmp -s "$src/plugin.js" "$PLUGIN_DIR/plugin.js" || fail "plugin.js wasn't restored"
assert_not_contains "$RUN_OUTPUT" "Backed up"
[ ! -e "$PLUGIN_DIR/plugin.js.bak" ] || fail "the step backed up the edit"

# open fails with -600 just after Stream Deck quits
echo "// an edit" >> "$PLUGIN_DIR/plugin.js"
stub pkill
stub sleep
stub open '[ -f "$SANDBOX/opened-once" ] && exit 0; touch "$SANDBOX/opened-once"; exit 1'
export SANDBOX
: > "$STUB_LOG"
assert_exit 0 main --no-backup
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin and its profiles."
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
assert_contains "$RUN_OUTPUT" "Stream Deck didn't quit; quit it and re-run the step"
assert_not_contains "$RUN_OUTPUT" "Restarted"
assert_file_not_contains "$STUB_LOG" "open -g"
stub pgrep 'exit 1'
assert_exit 0 main --no-backup

# Every action has a key image, and either switches pages or open-in or stats.js handles it
actions="$(jq -r '.Actions[].UUID' "$src/manifest.json" | tr '\n' ' ')"
open_in_targets="|$(sed -n 's/^# Usage: open-in //p' "$src/bin/open-in")|"
for action in $actions; do
    target="${action##*.}"
    jq -e --arg t "$target" '.links | has($t)' "$layout" > /dev/null || [[ "$open_in_targets" == *"|$target|"* ]] ||
        grep -qE "^  \"?$target\"?: \[" "$src/stats.js" ||
        fail "neither layout.json's links, open-in, nor stats.js handles $target"
done
for image in $(jq -r '.Icon, .CategoryIcon, (.Actions[] | .Icon, .States[].Image)' "$src/manifest.json"); do
    [ -f "$src/$image.svg" ] || [ -f "$src/$image.png" ] || fail "the manifest names $image, which isn't in the plugin"
done
assert_eq "$(layout_pages | while read -r page; do echo "profiles/$(profile_title "$page")"; done)" \
    "$(jq -r '.Profiles[].Name' "$src/manifest.json")" "the manifest's profiles, one per page of layout.json"
for page in $(jq -r '.links[]' "$layout"); do
    jq -e --arg p "$page" '.pages | has($p)' "$layout" > /dev/null || fail "layout.json links to $page, which it lacks"
done
for action in $(jq -r '.pages[][]' "$layout"); do
    [ -f "$src/images/key-$action.svg" ] || [ -f "$src/images/key-$action@2x.png" ] ||
        fail "layout.json's $action has no key-$action image in the plugin"
done

if ! command -v zip &> /dev/null || ! command -v unzip &> /dev/null; then
    skip_rest "the profile checks: zip or unzip isn't installed"
    test_done
    exit 0
fi

# The committed profiles must match a fresh build-profile.sh run byte for byte
assert_exit 0 bash "$REPO_DIR/stream-deck/build-profile.sh" "$SANDBOX/built"
for page in $(layout_pages); do
    title="$(profile_title "$page")"
    cmp -s "$src/profiles/$title.streamDeckProfile" "$SANDBOX/built/$title.streamDeckProfile" ||
        fail "the $title profile is out of date; run stream-deck/build-profile.sh"
done
# A relative path is the caller's, though zip runs elsewhere
mkdir -p "$SANDBOX/cwd"
# shellcheck disable=SC2016 # the inner shell expands them
assert_exit 0 bash -c 'cd "$1" && bash "$2" rel' _ "$SANDBOX/cwd" "$REPO_DIR/stream-deck/build-profile.sh"
cmp -s "$SANDBOX/built/Main.streamDeckProfile" "$SANDBOX/cwd/rel/Main.streamDeckProfile" ||
    fail "build-profile.sh with a relative path didn't build there"

profiles="$HOME/Library/Application Support/com.elgato.StreamDeck/ProfilesV3"
mkdir -p "$profiles"

# As Stream Deck installs a page's profile: in a folder of its own naming, with the fields it adds,
# and here with page folders in lowercase
fake_install() {
    local title dest="$profiles/$2" tmp folder
    title="$(profile_title "$1")"
    tmp="$(mktemp -d)"
    unzip -q "$src/profiles/$title.streamDeckProfile" -d "$tmp"
    mv "$tmp"/*.sdProfile "$dest"
    for folder in "$dest"/Profiles/*; do
        mv "$folder" "$folder.tmp"
        mv "$folder.tmp" "$(dirname "$folder")/$(basename "$folder" | tr '[:upper:]' '[:lower:]')"
    done
    jq --arg name "profiles/$title" '. + {InstalledByPluginUUID: "com.gpahal.dotfiles", PreconfiguredName: $name,
        ReadOnly: true} | .Device.UUID = "@(1)[4057/128/TEST]"' "$dest/manifest.json" > "$tmp/manifest.json"
    mv "$tmp/manifest.json" "$dest/manifest.json"
    rm -rf "$tmp"
}

# fake_profile <folder> <model> <name> <position>...: another profile, of Elgato's actions
fake_profile() {
    local dir="$1" model="$2" name="$3" page=0f1e2d3c-4b5a-4968-8776-5d4c3b2a1f0e actions="{}" key
    shift 3
    mkdir -p "$dir/Profiles/0F1E2D3C-4B5A-4968-8776-5D4C3B2A1F0E"
    for key in "$@"; do
        actions="$(jq -c --arg k "$key" '. + {($k): {UUID: "com.elgato.streamdeck.system.hotkey"}}' <<< "$actions")"
    done
    jq -n --arg model "$model" --arg name "$name" --arg page "$page" \
        '{Device: {Model: $model, UUID: "x"}, Name: $name, Pages: {Current: $page, Pages: [$page]}, Version: "3.0"}' \
        > "$dir/manifest.json"
    jq -n --argjson actions "$actions" '{Controllers: [{Actions: $actions, Type: "Keypad"}]}' \
        > "$dir/Profiles/0F1E2D3C-4B5A-4968-8776-5D4C3B2A1F0E/manifest.json"
}

fake_install main A1.sdProfile
fake_install system B2.sdProfile
fake_profile "$profiles/C3.sdProfile" 20GBA9901 "Default Profile" 0,2 1,2 4,0
fake_profile "$profiles/D4.sdProfile" 20GAT9901 "XL Profile" 0,0
# Not profile folders in ProfilesV3, so never deleted
fake_profile "$profiles/Backup" 20GBA9901 Backup 0,0
fake_profile "$SANDBOX/outside.sdProfile" 20GBA9901 Outside 0,0
ln -s "$SANDBOX/outside.sdProfile" "$profiles/Link.sdProfile"
mkdir -p "$profiles/E5.sdProfile"
echo "not json" > "$profiles/E5.sdProfile/manifest.json"

assert_exit 3 status
assert_contains "$RUN_OUTPUT" "ok         Stream Deck's Main profile"
assert_contains "$RUN_OUTPUT" "ok         Stream Deck's System profile"
assert_contains "$RUN_OUTPUT" "missing    extra Stream Deck profile Default Profile (3 keys): the next run deletes it"
assert_not_contains "$RUN_OUTPUT" "XL Profile"
assert_not_contains "$RUN_OUTPUT" "Backup"
assert_not_contains "$RUN_OUTPUT" "Outside"

# Other profiles for the deck go while Stream Deck is quit; the rest stay
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Deleted C3.sdProfile from Stream Deck's profiles: extra Stream Deck profile Default Profile (3 keys)"
assert_contains "$RUN_OUTPUT" "Restarted Stream Deck to load the plugin and its profiles."
assert_eq "pkill -x Stream Deck
pgrep -x Stream Deck
open -g -b com.elgato.StreamDeck" "$(cat "$STUB_LOG")" "commands run to delete a profile"
[ ! -e "$profiles/C3.sdProfile" ] || fail "the extra profile wasn't deleted"
for kept in A1.sdProfile B2.sdProfile D4.sdProfile Backup E5.sdProfile Link.sdProfile; do
    [ -e "$profiles/$kept" ] || fail "$kept was deleted"
done
[ -f "$SANDBOX/outside.sdProfile/manifest.json" ] || fail "a profile outside ProfilesV3 was deleted"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "" "$(cat "$STUB_LOG")" "commands run with the profiles in place"
assert_exit 0 status

# A copy whose keys differ from layout.json is reinstalled
jq '.Controllers[0].Actions["1,0"].UUID = "com.gpahal.dotfiles.files"' \
    "$profiles/B2.sdProfile/Profiles/$(profile_uuid page/system)/manifest.json" > "$SANDBOX/page.json"
mv "$SANDBOX/page.json" "$profiles/B2.sdProfile/Profiles/$(profile_uuid page/system)/manifest.json"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Stream Deck's System profile differs from layout.json: the next run reinstalls it"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Deleted B2.sdProfile from Stream Deck's profiles: Stream Deck's System profile differs from layout.json"
[ ! -e "$profiles/B2.sdProfile" ] && [ -e "$profiles/A1.sdProfile" ] || fail "the wrong profiles were deleted"

# Without the Main profile, Stream Deck would replace a deleted default profile, so it waits
rm -r "$profiles/A1.sdProfile"
fake_profile "$profiles/C3.sdProfile" 20GBA9901 "Default Profile" 0,2
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    extra Stream Deck profile Default Profile (1 key): deleted once the Main profile is installed"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "" "$(cat "$STUB_LOG")" "commands run with the Main profile missing"
[ -e "$profiles/C3.sdProfile" ] || fail "the default profile was deleted before the Main profile was installed"

# A changed archive, and a second copy, reinstall the plugin's profile
fake_install main A1.sdProfile
fake_install main A2.sdProfile
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    2 copies of Stream Deck's Main profile: the next run reinstalls it"
rm -r "$profiles/A2.sdProfile"
echo "stale" >> "$PLUGIN_DIR/profiles/Main.streamDeckProfile"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Deleted A1.sdProfile from Stream Deck's profiles: the plugin's Main profile changed"
assert_not_contains "$RUN_OUTPUT" "C3.sdProfile"
assert_file_contains "$STUB_LOG" "open -g -b com.elgato.StreamDeck"

# A Stream Deck that won't quit keeps its profiles
fake_install main A1.sdProfile
stub pgrep
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Stream Deck didn't quit"
[ -e "$profiles/C3.sdProfile" ] || fail "a profile was deleted while Stream Deck still ran"
stub pgrep 'exit 1'

# Not running: deleted with nothing to reopen
stub pkill 'exit 1'
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Deleted C3.sdProfile"
assert_eq "pkill -x Stream Deck" "$(cat "$STUB_LOG")" "commands run with Stream Deck not running"
test_done
