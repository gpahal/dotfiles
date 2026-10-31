#!/bin/bash
# smartd's warning hook (run.d/50dotfiles-notify), run as root; pushes to ntfy, always exits 0.

# Fixed paths, since it runs as root. Tests rewrite these lines (tests/ubuntu-sandbox.sh).
NTFY_URL_FILE="/etc/dotfiles/ntfy-url"
NTFY_TOKEN_FILE="/etc/dotfiles/ntfy-token"
NTFY_LIB="/usr/local/lib/dotfiles/ntfy.sh"
# smartd's PATH starts with /usr/local; use the system's curl and logger
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ ! -s "$NTFY_URL_FILE" ]; then
    logger -t dotfiles-smartd -- "couldn't push the warning to ntfy: the alerts aren't set up; run just ntfy-user" 2> /dev/null
    exit 0
fi
if [ ! -r "$NTFY_LIB" ]; then
    logger -t dotfiles-smartd -- "couldn't push the warning to ntfy: $NTFY_LIB is missing" 2> /dev/null
    exit 0
fi
# shellcheck source=lib/ntfy.sh
source "$NTFY_LIB"

ntfy_hook_push dotfiles-smartd "the warning" "${SMARTD_SUBJECT:-SMART warning on $(hostname)}" \
    "${SMARTD_MESSAGE:-${SMARTD_FULLMESSAGE:-smartd reported a problem with ${SMARTD_DEVICE:-a disk}}}" \
    "Priority: urgent" "Tags: warning"
exit 0
