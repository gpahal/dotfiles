# shellcheck shell=bash
# What the macOS open-in beside it and the Ubuntu one (stream-deck/linux/bin/open-in) share. Each
# sources it from its own folder, so every installed copy of either has it alongside. They set
# NEW_TAB_LOCK, CALLER_LOG, FRONT_KIND (app or window, whichever their front thing is),
# CONTEXT_PATH, and FAILURE.

# The callers timestamp each line
log() {
    printf '%s\n' "$*" >&2
}

usage() {
    echo "Usage: open-in files|editor|terminal|claude|chrome|chrome-tab|gmail|t3-code|activity-monitor" >&2
}

# Relies on zed/settings.json's window_title_format "${projectName}${separator}${filePath}"
zed_title_path() {
    case "$1" in
        *" — /"*) CONTEXT_PATH="/${1#*" — /"}" ;;
        *" — ~/"*) CONTEXT_PATH="$HOME/${1#*" — ~/"}" ;;
    esac
}

# Keeps CONTEXT_PATH only when it exists here: remote paths, such as a Zed project over SSH, don't
check_context_path() {
    [ "$CONTEXT_PATH" == / ] || CONTEXT_PATH="${CONTEXT_PATH%/}"
    [ -n "$CONTEXT_PATH" ] && [ -e "$CONTEXT_PATH" ] || CONTEXT_PATH=""
}

# open_path_result <target> <status>: notes a failure to open CONTEXT_PATH, unless one is noted
open_path_result() {
    [ "$2" -ne 0 ] && [ -z "$FAILURE" ] || return 0
    log "ERROR couldn't open ${CONTEXT_PATH:-a new window} for $1"
    FAILURE="Couldn't open ${CONTEXT_PATH:-a new window}. See $CALLER_LOG"
}

# One New Tab at a time, from the Stream Deck and the hotkeys alike: two at once would each open a
# tab, then both paste into whichever is in front. mkdir is atomic. A lock whose process is gone,
# or that got no process ID within a minute, is taken over.
take_new_tab_lock() {
    local pid=""
    if ! mkdir "$NEW_TAB_LOCK" 2> /dev/null; then
        read -r pid < "$NEW_TAB_LOCK/pid" 2> /dev/null
        if [ -n "$pid" ]; then
            ! kill -0 "$pid" 2> /dev/null || return 1
        elif [ -z "$(find "$NEW_TAB_LOCK" -maxdepth 0 -mmin +1 2> /dev/null)" ]; then
            return 1
        fi
        rm -rf "$NEW_TAB_LOCK"
        mkdir "$NEW_TAB_LOCK" 2> /dev/null || return 1
    fi
    echo "$$" > "$NEW_TAB_LOCK/pid"
    trap 'rm -rf "$NEW_TAB_LOCK"' EXIT
}

# new_tab_result <target> <new tab's status> <moved, if another app came to the front before the
# paste> <paste, if it pasted>
new_tab_result() {
    if [ "$2" -ne 0 ]; then
        [ -n "$FAILURE" ] || FAILURE="Couldn't open a new Chrome tab. See $CALLER_LOG"
    elif [ "$3" == moved ]; then
        log "$1: opened a new tab, but another $FRONT_KIND came to the front before the paste"
    elif [ "$4" == paste ]; then
        log "$1: opened a new tab with the clipboard pasted"
    else
        log "$1: opened a new tab"
    fi
}
