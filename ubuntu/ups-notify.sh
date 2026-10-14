#!/bin/bash
# upsmon's NOTIFYCMD, which the ubuntu step installs as /usr/local/libexec/dotfiles-ups-notify.
# On each event upsmon.conf flags EXEC, upsmon runs it as the nut user, with the message as its
# argument and NOTIFYTYPE and UPSNAME set. It pushes the event to ntfy when /etc/dotfiles/ntfy-url
# holds a topic's URL (bash ubuntu/setup-alerts.sh sets it), urgent for a low battery or a
# shutdown. It sources the ntfy code the step installs separately, since the nut user may not be
# able to read the repo. Failures go to the journal under dotfiles-ups. It always exits 0.

# Tests point these into their sandbox
NTFY_URL_FILE="${DOTFILES_NTFY_URL_FILE:-/etc/dotfiles/ntfy-url}"
NTFY_LIB="${DOTFILES_NTFY_LIB:-/usr/local/lib/dotfiles/ntfy.sh}"

log() {
    logger -t dotfiles-ups -- "$*" 2> /dev/null || true
}

[ -s "$NTFY_URL_FILE" ] || exit 0
if [ ! -r "$NTFY_LIB" ]; then
    log "couldn't push the UPS event to ntfy: $NTFY_LIB is missing"
    exit 0
fi
# shellcheck source=lib/ntfy.sh
source "$NTFY_LIB"

message="${1:-${UPSNAME:-The UPS} reported ${NOTIFYTYPE:-an event}}"
host="$(hostname 2> /dev/null || echo "this machine")"
case "${NOTIFYTYPE:-}" in
    ONBATT) title="UPS on battery" priority=high tags=electric_plug ;;
    ONLINE) title="UPS on mains power" priority=default tags=white_check_mark ;;
    LOWBATT) title="UPS battery low" priority=urgent tags=warning ;;
    SHUTDOWN) title="Shutting down on UPS battery" priority=urgent tags=warning ;;
    REPLBATT) title="UPS battery needs replacing" priority=high tags=warning ;;
    COMMBAD | NOCOMM) title="Lost contact with the UPS" priority=high tags=warning ;;
    COMMOK) title="Back in contact with the UPS" priority=default tags=white_check_mark ;;
    *) title="UPS event ${NOTIFYTYPE:-}" priority=default tags=electric_plug ;;
esac
if ! out="$(ntfy_push "$(head -n 1 "$NTFY_URL_FILE")" "$title on $host" "$message" \
    "Priority: $priority" "Tags: $tags" 2>&1)"; then
    log "couldn't push the UPS event to ntfy: ${out:-curl failed}"
fi
exit 0
