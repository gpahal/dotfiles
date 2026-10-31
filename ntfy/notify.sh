#!/bin/bash
set -u

# Show one ntfy message as a desktop notification, once; ntfy subscribe runs it per message.
# The message comes in NTFY_ID, NTFY_TIME, NTFY_TOPIC, NTFY_TITLE, NTFY_MESSAGE and NTFY_PRIORITY.
# ntfy replays its cache after every reconnect (subscribe.sh), so an ID already shown is skipped,
# and the newest message time is kept for the next start to resume from. The ntfy step copies it
# to ~/.local/share/dotfiles/ntfy, so it mustn't depend on the repo.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ntfy"
SEEN_FILE="$STATE_DIR/seen"
SEEN_MAX=1000
LAST_TIME_FILE="$STATE_DIR/last-time"
# The ntfy step's status reports it while it exists
ERROR_FILE="$STATE_DIR/notify-error"

id="${NTFY_ID:-}"
[ -n "$id" ] || exit 0
mkdir -p "$STATE_DIR" || exit 1
! grep -qxF -- "$id" "$SEEN_FILE" 2> /dev/null || exit 0

# Seen before it shows, so a broken notifier doesn't make every reconnect show it again. A rename,
# so a crash can't leave the list cut short.
remember() {
    local tmp
    tmp="$(mktemp "$STATE_DIR/.seen.XXXXXX")" || return 1
    if { tail -n $((SEEN_MAX - 1)) "$SEEN_FILE" 2> /dev/null || true; printf '%s\n' "$id"; } > "$tmp" &&
        mv -f "$tmp" "$SEEN_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

record_time() {
    local time="${NTFY_TIME:-}" last
    case "$time" in '' | *[!0-9]*) return 0 ;; esac
    last="$(head -n 1 "$LAST_TIME_FILE" 2> /dev/null)" || last=""
    case "$last" in '' | *[!0-9]*) last=0 ;; esac
    [ "$time" -le "$last" ] || printf '%s\n' "$time" > "$LAST_TIME_FILE"
}

# terminal-notifier's exit codes 3 and 4: not allowed, and no GUI session
record_error() {
    local why
    case "$1" in
        3) why="macOS doesn't allow terminal-notifier's notifications; allow them in System Settings → Notifications → terminal-notifier" ;;
        4) why="terminal-notifier found no GUI session to show it in" ;;
        *) why="terminal-notifier exited $1" ;;
    esac
    printf '%s (%s)\n' "$why" "$(date '+%Y-%m-%d %H:%M')" > "$ERROR_FILE"
}

remember || exit 1
record_time
title="${NTFY_TITLE:-}"
[ -n "$title" ] || title="${NTFY_TOPIC:-ntfy}"
message="${NTFY_MESSAGE:-}"
[ -n "$message" ] || message="$title"
priority="${NTFY_PRIORITY:-3}"
case "$priority" in [1-5]) ;; *) priority=3 ;; esac

status=0
if [ "$(uname -s)" == Darwin ]; then
    args=(-title "$title" -message "$message" -group "ntfy-$id")
    [ "$priority" -lt 4 ] || args+=(-sound default)
    terminal-notifier "${args[@]}" > /dev/null 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$ERROR_FILE"
    else
        record_error "$status"
    fi
else
    urgency=normal
    [ "$priority" -lt 4 ] || urgency=critical
    notify-send --app-name=ntfy --urgency="$urgency" -- "$title" "$message" || status=$?
fi
exit "$status"
