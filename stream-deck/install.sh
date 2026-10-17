#!/bin/bash
set -euo pipefail

# Install the Stream Deck plugin in stream-deck/com.gpahal.dotfiles.sdPlugin. Its Editor,
# Terminal, and Files actions open the folder or file in front in Zed, Ghostty, or Finder. Its
# bin/open-in says how it finds them. Its Chrome, New Tab, Gmail, T3 Code, and Claude actions
# run bin/open-app, which does what the matching Hammerspoon hotkeys do, and also finds Chrome's
# Gmail tab. The hammerspoon step copies bin/open-in too, for its Ctrl+Opt+T and E. The plugin's
# stat keys, which plugin.js describes, show live CPU, memory, and other stats, and its Overview
# key opens a page of them. Stream Deck loads plugins when it starts, so a run that changes the
# plugin restarts a running Stream Deck. macOS only, since Stream Deck has no Linux app. The
# homebrew step installs Stream Deck.
#
# A temp HOME doesn't isolate this step, which restarts the Stream Deck you're running when the
# plugin changed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PLUGIN=com.gpahal.dotfiles.sdPlugin
PLUGIN_DIR="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/$PLUGIN"
# Listed rather than found, so a stray file in the repo, such as a .DS_Store, isn't installed
PLUGIN_FILES="manifest.json plugin.js stats.js bin/open-in bin/open-app
profiles/System.streamDeckProfile images/plugin.png images/plugin@2x.png images/category.svg
images/overview.svg images/editor.svg images/terminal.svg images/files.svg images/chrome.svg
images/chrome-tab.svg images/gmail.svg images/t3-code.svg images/claude.svg images/key-overview.svg
images/key-editor.png images/key-editor@2x.png images/key-terminal.png images/key-terminal@2x.png
images/key-files.svg images/key-chrome.svg images/key-chrome-tab.svg images/key-gmail.svg
images/key-t3-code.png images/key-t3-code@2x.png images/key-claude.svg
images/cpu.svg images/memory.svg images/swap.svg images/top.svg images/gpu.svg
images/temperature.svg images/power.svg images/disk.svg images/network.svg
images/activity-monitor.svg images/back.svg images/key-cpu.svg
images/key-memory.svg images/key-swap.svg images/key-top.svg images/key-gpu.svg
images/key-temperature.svg images/key-power.svg images/key-disk.svg images/key-network.svg
images/key-activity-monitor.svg images/key-back.svg"

# Pass each plugin file, as source and destination, to a function: copy_plugin_file to copy it,
# or status_file to report it
each_plugin_file() {
    local action="$1" file status=0
    for file in $PLUGIN_FILES; do
        "$action" "$DOTFILES_DIR/stream-deck/$PLUGIN/$file" "$PLUGIN_DIR/$file" || status=1
    done
    return "$status"
}

# Set when an installed file differs, so main restarts Stream Deck after copying
PLUGIN_CHANGED=false

copy_plugin_file() {
    cmp -s "$1" "$2" || PLUGIN_CHANGED=true
    copy_file "$1" "$2"
}

# SIGTERM quits Stream Deck; it saves profile changes as they're made. open fails with error -600
# while the old process is still quitting, so wait for it to go first. LaunchServices can still
# report -600 for a moment after the process is gone, so open is tried a few times.
restart_stream_deck() {
    local opened=false
    if ! pkill -x "Stream Deck"; then
        echo "  Stream Deck isn't running; it loads the plugin when it starts."
        return 0
    fi
    for _ in $(seq 1 20); do
        pgrep -x "Stream Deck" > /dev/null || break
        sleep 0.5
    done
    for _ in 1 2 3 4 5; do
        if open -g -b com.elgato.StreamDeck; then
            opened=true
            break
        fi
        sleep 1
    done
    if ! "$opened"; then
        echo "  Couldn't reopen Stream Deck. Open it to load the plugin." >&2
        return 1
    fi
    echo "  Restarted Stream Deck to load the plugin."
}

status() {
    if ! is_macos; then
        status_item skipped "Stream Deck plugin: Stream Deck has no Linux app"
        return 0
    fi
    each_plugin_file status_file
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Installing the Stream Deck plugin..."
    if ! is_macos; then
        echo "  Stream Deck has no Linux app; skipping."
        return 0
    fi
    local status=0
    each_plugin_file copy_plugin_file || status=1
    if "$PLUGIN_CHANGED"; then
        restart_stream_deck || status=1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
