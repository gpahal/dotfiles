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

# The sequence ID, so smartd repeating a warning replaces its notification: the disk and the kind
# of failure, in the letters, digits, and dashes ntfy allows, at most 64
device="${SMARTD_DEVICE:-disk}"
sequence="$(printf 'smart-%s-%s' "${device##*/}" "${SMARTD_FAILTYPE:-warning}" | LC_ALL=C tr -c 'A-Za-z0-9_-' - |
    cut -c 1-64)"
ntfy_hook_push dotfiles-smartd "the warning" "${SMARTD_SUBJECT:-SMART warning on $(hostname)}" \
    "${SMARTD_MESSAGE:-${SMARTD_FULLMESSAGE:-smartd reported a problem with ${SMARTD_DEVICE:-a disk}}}" \
    "Priority: urgent" "Tags: warning,action:linux-disk" "X-Sequence-ID: $sequence"
exit 0
