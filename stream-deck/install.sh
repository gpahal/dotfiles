#!/bin/bash
set -euo pipefail

# Install the Stream Deck plugin, and restart Stream Deck to load it.
# A temp HOME doesn't isolate it: it restarts the running Stream Deck when the plugin changed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

STEP_OS=macos

PLUGIN=com.gpahal.dotfiles.sdPlugin
PLUGIN_DIR="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/$PLUGIN"

# Backups aren't plugin files, so never count as stale
plugin_file_list() {
    (cd "${1:-$DOTFILES_DIR/stream-deck/$PLUGIN}" &&
        find . -type f ! -name .DS_Store ! -name '*.bak' ! -name '*.bak.*' | sed 's|^\./||')
}

stale_plugin_list() {
    [ -d "$PLUGIN_DIR" ] || return 0
    LC_ALL=C comm -13 <(plugin_file_list | LC_ALL=C sort) <(plugin_file_list "$PLUGIN_DIR" | LC_ALL=C sort)
}

each_plugin_file() {
    local action="$1" file status=0
    while IFS= read -r file; do
        "$action" "$DOTFILES_DIR/stream-deck/$PLUGIN/$file" "$PLUGIN_DIR/$file" || status=1
    done < <(plugin_file_list)
    return "$status"
}

# Sets COPIED so Stream Deck restarts
remove_stale_plugin() {
    local file status=0
    while IFS= read -r file; do
        if rm -f "$PLUGIN_DIR/$file"; then
            echo "  Removed $file, which the repo's plugin no longer has"
            COPIED=true
        else
            status=1
        fi
    done < <(stale_plugin_list)
    find "$PLUGIN_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    return "$status"
}

# SIGTERM is safe: Stream Deck saves as it goes. open fails with -600 while the old process quits
# and briefly after, hence the wait and retries.
restart_stream_deck() {
    local opened=false
    if ! pkill -x "Stream Deck"; then
        echo "  Stream Deck isn't running; it loads the plugin when it starts."
        return 0
    fi
    if ! wait_until_quit -x "Stream Deck"; then
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
    each_plugin_file status_file
    while IFS= read -r file; do
        status_item missing "$file in the installed plugin: the repo's plugin no longer has it; re-run the stream-deck step to remove it"
    done < <(stale_plugin_list)
    status_result
}

apply() {
    echo "Installing the Stream Deck plugin..."
    local status=0
    COPIED=false
    each_plugin_file copy_file || status=1
    remove_stale_plugin || status=1
    if "$COPIED"; then
        restart_stream_deck || status=1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
