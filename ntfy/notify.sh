#!/bin/bash
set -u

# Show one ntfy message as a desktop notification, once; ntfy subscribe runs it per message.
# The message comes in NTFY_ID, NTFY_TIME, NTFY_TOPIC, NTFY_TITLE, NTFY_MESSAGE, NTFY_PRIORITY,
# NTFY_TAGS, and NTFY_RAW, the whole message as JSON, which holds its Click link and actions.
# A click opens the message's link, or runs the action its action:<name> tag names (actions.sh) in
# a new Ghostty tab, through the Stream Deck's open-in, once you press Enter there.
# ntfy replays its cache after every reconnect (subscribe.sh), so an ID already shown is skipped,
# and the newest message time is kept for the next start to resume from. The ntfy step copies it
# to ~/.local/share/dotfiles/ntfy, so it mustn't depend on the repo.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ntfy"
SEEN_FILE="$STATE_DIR/seen"
SEEN_MAX=1000
LAST_TIME_FILE="$STATE_DIR/last-time"
# The ntfy step's status reports it while it exists
ERROR_FILE="$STATE_DIR/notify-error"
# What a click on an agenda message opens when the message has no link of its own
AGENDA_URL=https://garvitpahal.com/x/agenda
# Beside it: actions.sh, run-action.sh, and open-in, which writes what it did here
NOTIFIER_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_LOG="$STATE_DIR/action.log"
# shellcheck source=actions.sh
source "$NOTIFIER_DIR/actions.sh" || exit 1

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

# web_url <url>: the URL if it's http or https, so a message can't open a file or start an app
web_url() {
    case "$1" in
        *[[:space:]]*) ;;
        http://?* | https://?*) printf '%s' "$1" ;;
    esac
}

# Sets ACTION and ACTION_LABEL from the action:<name> tag, when it's an action this computer can
# run, and LINK, what a click opens: the message's Click link, else its first view action's URL,
# else, with no action, the topic's page. VIEW_URLS and VIEW_LABELS get the view actions, which
# Ubuntu shows as buttons. ntfy's http and broadcast actions only work in its Android app.
read_links() {
    local url label
    ACTION=""
    ACTION_LABEL=""
    if ACTION="$(action_from_tags "${NTFY_TAGS:-}")" && ! action_resolve "$ACTION"; then
        ACTION=""
    fi
    LINK=""
    VIEW_URLS=()
    VIEW_LABELS=()
    if [ -n "${NTFY_RAW:-}" ] && command -v jq > /dev/null 2>&1; then
        LINK="$(web_url "$(jq -r '.click // empty | strings' <<< "$NTFY_RAW" 2> /dev/null)")"
        while IFS=$'\t' read -r url label; do
            url="$(web_url "$url")"
            [ -n "$url" ] || continue
            VIEW_URLS+=("$url")
            VIEW_LABELS+=("${label:-Open}")
        done < <(jq -r '.actions[]? | select(.action == "view" and (.url | type) == "string")
            | "\(.url)\t\(.label // "" | tostring | gsub("[\t\n\r]"; " "))"' <<< "$NTFY_RAW" 2> /dev/null)
    fi
    if [ -z "$LINK" ] && [ "${#VIEW_URLS[@]}" -gt 0 ]; then
        LINK="${VIEW_URLS[0]}"
    fi
    if [ -z "$LINK" ] && [ -z "$ACTION" ] && [ "${NTFY_TOPIC:-}" == agenda ]; then
        LINK="$AGENDA_URL"
    fi
}

# The open-in command that opens a Ghostty tab running run-action.sh for ACTION, whose name is only
# letters, digits, and dashes
action_open_in() {
    printf 'OPEN_IN_CALLER=ntfy OPEN_IN_LOG=%s /bin/bash %s run %s > %s 2>&1' "$(sh_quote "$ACTION_LOG")" \
        "$(sh_quote "$NOTIFIER_DIR/open-in")" \
        "$(sh_quote "/bin/bash $(sh_quote "$NOTIFIER_DIR/run-action.sh") $ACTION")" "$(sh_quote "$ACTION_LOG")"
}

# notify-send --wait prints the action clicked: default for the notification itself, a view
# action's index, or action. It returns once the notification is clicked or dismissed.
open_on_click() {
    local choice url=""
    choice="$(notify-send "$@")" || return 1
    case "$choice" in
        default) url="$LINK" ;;
        [0-9]) [ "$choice" -ge "${#VIEW_URLS[@]}" ] || url="${VIEW_URLS[$choice]}" ;;
    esac
    if [ -n "$url" ]; then
        xdg-open "$url"
    elif [ -n "$ACTION" ] && { [ "$choice" == action ] || [ "$choice" == default ]; }; then
        sh -c "$(action_open_in)"
    fi
}

remember || exit 1
record_time
title="${NTFY_TITLE:-}"
[ -n "$title" ] || title="${NTFY_TOPIC:-ntfy}"
message="${NTFY_MESSAGE:-}"
[ -n "$message" ] || message="$title"
priority="${NTFY_PRIORITY:-3}"
case "$priority" in [1-5]) ;; *) priority=3 ;; esac
read_links

status=0
if [ "$(uname -s)" == Darwin ]; then
    # terminal-notifier has no buttons, so a click opens the link, else runs the action, and the
    # other actions are left out. It runs -execute through sh.
    args=(-title "$title" -message "$message" -group "ntfy-$id")
    if [ -n "$LINK" ]; then
        args+=(-open "$LINK")
    elif [ -n "$ACTION" ]; then
        args+=(-execute "$(action_open_in)")
    fi
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
    args=(--app-name=ntfy --urgency="$urgency")
    if [ -z "$LINK" ] && [ -z "$ACTION" ]; then
        notify-send "${args[@]}" -- "$title" "$message" || status=$?
    else
        # In the background, as it waits for the click, so ntfy goes on to the next message. Its
        # output goes to /dev/null, so ntfy isn't left waiting on it either. GNOME shows the
        # default action as a click on the notification, not a button.
        args+=(--wait --action=default=Open)
        i=0
        while [ "$i" -lt "${#VIEW_URLS[@]}" ]; do
            args+=("--action=$i=${VIEW_LABELS[$i]}")
            i=$((i + 1))
        done
        [ -z "$ACTION" ] || args+=("--action=action=$ACTION_LABEL")
        open_on_click "${args[@]}" -- "$title" "$message" < /dev/null > /dev/null 2>&1 &
    fi
fi
exit "$status"
