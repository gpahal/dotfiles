#!/bin/bash
set -u

# Show one ntfy message as a desktop notification, once; ntfy subscribe runs it per message.
# The message comes in NTFY_ID, NTFY_TIME, NTFY_TOPIC, NTFY_TITLE, NTFY_MESSAGE, NTFY_PRIORITY,
# NTFY_TAGS, and NTFY_RAW, the whole message as JSON, which holds its Click link, actions, and
# sequence ID.
# A message with a sequence ID replaces the notification of the last one with that ID in its topic,
# as on the phone, so an alert that repeats or clears shows once.
# A click opens the message's link, or runs the action its action:<name> tag names (actions.sh) in
# a new Ghostty tab, through the Stream Deck's open-in, once you press Enter there. On Ubuntu,
# GNOME tells clicks.sh of the click, which reads what to do from the file this saves.
# ntfy replays its cache after every reconnect (subscribe.sh), so an ID already shown is skipped,
# and the newest message time is kept for the next start to resume from. The ntfy step copies it
# to ~/.local/share/dotfiles/ntfy, so it mustn't depend on the repo.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ntfy"
SEEN_FILE="$STATE_DIR/seen"
SEEN_MAX=1000
LAST_TIME_FILE="$STATE_DIR/last-time"
# The ntfy step's status reports it while it exists
ERROR_FILE="$STATE_DIR/notify-error"
# What a click on each Ubuntu notification does, for clicks.sh; kept as long as GNOME may still
# show the notification
CLICKS_DIR="$STATE_DIR/clicks"
CLICKS_DAYS=30
# The ntfy step's dotfiles.ntfy.desktop, which GNOME groups the notifications under
GTK_APP_ID=dotfiles.ntfy
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

# id_part <string>: only letters, digits, dashes, and underscores, as ntfy's topics, IDs, and
# sequence IDs are, so it's safe in a file name and a notification ID
id_part() {
    printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' _
}

# Sets KEY, which names the notification: the topic and the message's sequence ID, else its ID, so
# a message with the same sequence ID replaces it
read_key() {
    local sequence=""
    if [ -n "${NTFY_RAW:-}" ] && command -v jq > /dev/null 2>&1; then
        sequence="$(jq -r '.sequence_id // empty | strings' <<< "$NTFY_RAW" 2> /dev/null)" || sequence=""
    fi
    [ -n "$sequence" ] || sequence="$id"
    KEY="$(id_part "${NTFY_TOPIC:-ntfy}")-$(id_part "$sequence")"
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

# What clicks.sh reads for the notification: a line per link, view action URL, and action. URLs
# have no spaces (web_url). A rename, so a click never reads it half written; a notification that
# replaces one with links but has none leaves no file.
save_clicks() {
    local file="$CLICKS_DIR/$KEY" tmp url
    find "$CLICKS_DIR" -type f -mtime +"$CLICKS_DAYS" -exec rm -f {} + 2> /dev/null
    if [ -z "$LINK" ] && [ -z "$ACTION" ]; then
        rm -f "$file"
        return 0
    fi
    mkdir -p "$CLICKS_DIR" && tmp="$(mktemp "$CLICKS_DIR/.click.XXXXXX")" || return 1
    {
        [ -z "$LINK" ] || printf 'link %s\n' "$LINK"
        for url in ${VIEW_URLS[@]+"${VIEW_URLS[@]}"}; do
            printf 'view %s\n' "$url"
        done
        [ -z "$ACTION" ] || printf 'action %s\n' "$ACTION"
    } > "$tmp" && mv -f "$tmp" "$file" && return 0
    rm -f "$tmp"
    return 1
}

# gtk_notify <priority>: through GNOME's org.gtk.Notifications, which groups the notifications
# under the app, keeps them until you dismiss them, even across a restart, and replaces one with
# the same ID. busctl takes each value as its own argument, so nothing in a message needs quoting.
# GNOME shows the default action as a click on the notification, not a button.
gtk_notify() {
    local fields=(title s "$title" body s "$message" priority s "$1" default-action s default)
    local count=4 buttons=() i=0
    while [ "$i" -lt "${#VIEW_URLS[@]}" ]; do
        buttons+=(2 label s "${VIEW_LABELS[$i]}" action s "view$i")
        i=$((i + 1))
    done
    [ -z "$ACTION" ] || { buttons+=(2 label s "$ACTION_LABEL" action s action) && i=$((i + 1)); }
    if [ "$i" -gt 0 ]; then
        fields+=(buttons 'aa{sv}' "$i" "${buttons[@]}")
        count=5
    fi
    busctl --user call org.gtk.Notifications /org/gtk/Notifications org.gtk.Notifications \
        AddNotification 'ssa{sv}' "$GTK_APP_ID" "$KEY" "$count" "${fields[@]}" > /dev/null 2>&1
}

remember || exit 1
record_time
title="${NTFY_TITLE:-}"
[ -n "$title" ] || title="${NTFY_TOPIC:-ntfy}"
message="${NTFY_MESSAGE:-}"
[ -n "$message" ] || message="$title"
priority="${NTFY_PRIORITY:-3}"
case "$priority" in [1-5]) ;; *) priority=3 ;; esac
read_key
read_links

status=0
if [ "$(uname -s)" == Darwin ]; then
    # terminal-notifier has no buttons, so a click opens the link, else runs the action, and the
    # other actions are left out. It runs -execute through sh. A notification replaces the one in
    # its group.
    args=(-title "$title" -message "$message" -group "ntfy-$KEY")
    if [ -n "$LINK" ]; then
        args+=(-open "$LINK")
    elif [ -n "$ACTION" ]; then
        args+=(-execute "$(action_open_in "$NOTIFIER_DIR" "$ACTION" "$ACTION_LOG")")
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
    [ "$priority" -lt 4 ] || urgency=urgent
    save_clicks || status=1
    # notify-send when GNOME's API isn't there, as outside GNOME or before the ntfy step installs
    # the app: each notification on its own, which a click only dismisses
    if ! gtk_notify "$urgency"; then
        [ "$urgency" == normal ] || urgency=critical
        notify-send --app-name=ntfy --urgency="$urgency" -- "$title" "$message" || status=$?
    fi
fi
exit "$status"
