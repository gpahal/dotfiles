#!/bin/bash
# upsmon's NOTIFYCMD, run as nut; pushes the UPS event to ntfy, always exits 0.

# Fixed paths, since it runs as nut. Tests rewrite these lines (tests/ubuntu-sandbox.sh).
NTFY_URL_FILE="/etc/dotfiles/ntfy-url"
NTFY_TOKEN_FILE="/etc/dotfiles/ntfy-token"
NTFY_LIB="/usr/local/lib/dotfiles/ntfy.sh"
# upsmon's PATH starts with /usr/local; use the system's curl and logger
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ ! -s "$NTFY_URL_FILE" ]; then
    logger -t dotfiles-ups -- "couldn't push the UPS event to ntfy: the alerts aren't set up; run just ntfy-user" 2> /dev/null
    exit 0
fi
if [ ! -r "$NTFY_LIB" ]; then
    logger -t dotfiles-ups -- "couldn't push the UPS event to ntfy: $NTFY_LIB is missing" 2> /dev/null
    exit 0
fi
# shellcheck source=lib/ntfy.sh
source "$NTFY_LIB"

message="${1:-${UPSNAME:-The UPS} reported ${NOTIFYTYPE:-an event}}"
host="$(hostname 2> /dev/null || echo "this machine")"
# The sequence ID: an event replaces the notification of the last one about the same thing, so
# back on mains power replaces on battery
case "${NOTIFYTYPE:-}" in
    ONBATT) title="UPS on battery" priority=high tags=electric_plug sequence=ups-power ;;
    ONLINE) title="UPS on mains power" priority=default tags=white_check_mark sequence=ups-power ;;
    LOWBATT) title="UPS battery low" priority=urgent tags=warning sequence=ups-power ;;
    SHUTDOWN) title="Shutting down on UPS battery" priority=urgent tags=warning sequence=ups-power ;;
    REPLBATT) title="UPS battery needs replacing" priority=high tags=warning sequence=ups-battery ;;
    COMMBAD | NOCOMM) title="Lost contact with the UPS" priority=high tags=warning sequence=ups-comm ;;
    COMMOK) title="Back in contact with the UPS" priority=default tags=white_check_mark sequence=ups-comm ;;
    *) title="UPS event ${NOTIFYTYPE:-}" priority=default tags=electric_plug sequence=ups-other ;;
esac
ntfy_hook_push dotfiles-ups "the UPS event" "$title on $host" "$message" "Priority: $priority" \
    "Tags: $tags,action:linux-ups" "X-Sequence-ID: $sequence"
exit 0
