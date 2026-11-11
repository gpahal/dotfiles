#!/bin/bash
set -u

# Act on clicks on the ntfy notifications notify.sh shows on Ubuntu through GNOME's
# org.gtk.Notifications: open the link notify.sh saved for the notification, or run its action
# (actions.sh) in a new Ghostty tab, through the Stream Deck's open-in, once you press Enter there.
# GNOME emits ActionInvoked for each click; gdbus monitor follows GNOME Shell across restarts, and
# when it exits, so does this, for the user unit to restart it. The ntfy step copies it to
# ~/.local/share/dotfiles/ntfy, so it mustn't depend on the repo.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ntfy"
CLICKS_DIR="$STATE_DIR/clicks"
ACTION_LOG="$STATE_DIR/action.log"
# Beside it: actions.sh, run-action.sh, and open-in
NOTIFIER_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=actions.sh
source "$NOTIFIER_DIR/actions.sh" || exit 1
# gdbus monitor's line for a click on one of notify.sh's notifications: its ID, and default for the
# notification itself, view<n> for a view action's button, or action for the action's
CLICK_RE="^/org/gtk/Notifications: org\.gtk\.Notifications\.ActionInvoked \('dotfiles\.ntfy', '([A-Za-z0-9_-]+)', '(default|action|view[0-9])',"

# on_click <notification ID> <choice>. The file stays, so a second click does the same.
on_click() {
    local file="$CLICKS_DIR/$1" kind value link="" action="" url="" views=() n
    [ -f "$file" ] || return 0
    while read -r kind value; do
        case "$kind" in
            link) link="$value" ;;
            view) views+=("$value") ;;
            action) action="$value" ;;
        esac
    done < "$file"
    case "$2" in
        default) url="$link" ;;
        view*)
            n="${2#view}"
            [ "$n" -ge "${#views[@]}" ] || url="${views[$n]}"
            ;;
    esac
    if [ -n "$url" ]; then
        xdg-open "$url" < /dev/null > /dev/null 2>&1 &
    elif [ -n "$action" ] && { [ "$2" == action ] || [ "$2" == default ]; } && action_resolve "$action"; then
        sh -c "$(action_open_in "$NOTIFIER_DIR" "$action" "$ACTION_LOG")" < /dev/null > /dev/null 2>&1 &
    fi
}

while IFS= read -r line; do
    [[ "$line" =~ $CLICK_RE ]] || continue
    on_click "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
done < <(gdbus monitor --session --dest org.gtk.Notifications)
echo "gdbus monitor stopped, so clicks on ntfy's notifications do nothing until this restarts." >&2
exit 1
