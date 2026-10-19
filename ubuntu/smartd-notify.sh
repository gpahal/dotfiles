#!/bin/bash
# smartd's warning hook, which the ubuntu step installs as
# /etc/smartmontools/run.d/50dotfiles-notify. On a warning, smartd runs smartd-runner (the -M exec
# in Ubuntu's default smartd.conf), which runs each file in run.d as root with SMARTD_SUBJECT,
# SMARTD_MESSAGE, SMARTD_DEVICE, and SMARTD_FAILTYPE set. This one pushes the warning to ntfy
# when /etc/dotfiles/ntfy-url holds a topic's URL (bash ubuntu/setup-alerts.sh sets it). It runs
# away from the repo, so it sources the ntfy code the step installs with it. Failures go to the
# journal under dotfiles-smartd. It always exits 0, so run-parts reports no failure for it.

# Fixed paths, not variables a caller could set, since the hook runs as root. Tests run a
# copy with these lines rewritten (ntfy_hook_copy in tests/lib.sh).
NTFY_URL_FILE="/etc/dotfiles/ntfy-url"
NTFY_LIB="/usr/local/lib/dotfiles/ntfy.sh"
# smartd's PATH starts with /usr/local, so a curl or logger there would run instead of the system's
PATH=/usr/sbin:/usr/bin:/sbin:/bin

[ -s "$NTFY_URL_FILE" ] || exit 0
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
