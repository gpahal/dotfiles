#!/bin/bash
set -euo pipefail

# Install the Stream Deck plugin in stream-deck/com.gpahal.dotfiles.sdPlugin. Each of its app
# actions runs bin/open-in, which says what each does: Editor, Terminal, and Files open the folder
# or file in front in Zed, Ghostty, or Finder, and Chrome, New Tab, Gmail, T3 Code, and Claude do
# what the matching Hammerspoon hotkeys do. The hammerspoon step copies bin/open-in too, for its
# Ctrl+Opt+Cmd+T and E. The plugin's stat keys, which plugin.js describes, show live CPU, memory,
# and other stats, and its Overview key opens a page of them. A file the repo's plugin no longer
# has is removed from the installed plugin. Stream Deck loads plugins when it starts, so a run
# that changes the plugin restarts a running Stream Deck. macOS only, since Stream Deck has no
# Linux app. The homebrew step installs Stream Deck.
#
# A temp HOME doesn't isolate this step, which restarts the Stream Deck you're running when the
# plugin changed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PLUGIN=com.gpahal.dotfiles.sdPlugin
PLUGIN_DIR="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/$PLUGIN"

# Print each file in a plugin dir, the repo's by default, relative to it. A .DS_Store Finder
# leaves isn't one.
plugin_file_list() {
    # Backups copy_file makes of edited files aren't plugin files, so they never count as stale
    (cd "${1:-$DOTFILES_DIR/stream-deck/$PLUGIN}" &&
        find . -type f ! -name .DS_Store ! -name '*.bak' ! -name '*.bak.*' | sed 's|^\./||')
}

# Print each file in the installed plugin that the repo's plugin no longer has
stale_plugin_files() {
    [ -d "$PLUGIN_DIR" ] || return 0
    LC_ALL=C comm -13 <(plugin_file_list | LC_ALL=C sort) <(plugin_file_list "$PLUGIN_DIR" | LC_ALL=C sort)
}

# Pass each plugin file, as source and destination, to a function: copy_file to copy it, or
# status_file to report it
each_plugin_file() {
    local action="$1" file status=0
    while IFS= read -r file; do
        "$action" "$DOTFILES_DIR/stream-deck/$PLUGIN/$file" "$PLUGIN_DIR/$file" || status=1
    done < <(plugin_file_list)
    return "$status"
}

# Remove the installed plugin's files that the repo's plugin no longer has, and the folders that
# leaves empty, only ever inside PLUGIN_DIR. Sets COPIED when it removes one, so Stream Deck
# restarts without it.
remove_stale_plugin_files() {
    local file status=0
    while IFS= read -r file; do
        if rm -f "$PLUGIN_DIR/$file"; then
            echo "  Removed $file, which the repo's plugin no longer has"
            COPIED=true
        else
            status=1
        fi
    done < <(stale_plugin_files)
    find "$PLUGIN_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    return "$status"
}

# SIGTERM quits Stream Deck; it saves profile changes as they're made. open fails with error -600
# while the old process is still quitting, so wait for it to go first. LaunchServices can still
# report -600 for a moment after the process is gone, so open is tried a few times.
restart_stream_deck() {
    local opened=false quit=false
    if ! pkill -x "Stream Deck"; then
        echo "  Stream Deck isn't running; it loads the plugin when it starts."
        return 0
    fi
    for _ in $(seq 1 20); do
        if ! pgrep -x "Stream Deck" > /dev/null; then
            quit=true
            break
        fi
        sleep 0.5
    done
    if ! "$quit"; then
        echo "  Stream Deck didn't quit; quit and reopen it to load the plugin." >&2
        return 1
    fi
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
    local file
    if ! is_macos; then
        status_item skipped "Stream Deck plugin: Stream Deck has no Linux app"
        return 0
    fi
    each_plugin_file status_file
    while IFS= read -r file; do
        status_item missing "$file in the installed plugin: the repo's plugin no longer has it; re-run the stream-deck step to remove it"
    done < <(stale_plugin_files)
    status_result
}

apply() {
    echo "Installing the Stream Deck plugin..."
    if ! is_macos; then
        echo "  Stream Deck has no Linux app; skipping."
        return 0
    fi
    local status=0
    COPIED=false
    each_plugin_file copy_file || status=1
    remove_stale_plugin_files || status=1
    if "$COPIED"; then
        restart_stream_deck || status=1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
