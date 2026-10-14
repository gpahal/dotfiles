#!/bin/bash
# smartd's warning hook, which the ubuntu step installs as
# /etc/smartmontools/run.d/50dotfiles-notify. On a warning, smartd runs smartd-runner (the -M exec
# in Ubuntu's default smartd.conf), which runs each file in run.d as root with SMARTD_SUBJECT,
# SMARTD_MESSAGE, SMARTD_DEVICE, and SMARTD_FAILTYPE set. This one pushes the warning to ntfy
# when /etc/dotfiles/ntfy-url holds a topic's URL (bash ubuntu/setup-alerts.sh sets it). It runs
# away from the repo, so it sources the ntfy code the step installs with it. Failures go to the
# journal under dotfiles-smartd. It always exits 0, so run-parts reports no failure for it.

# Tests point these into their sandbox
NTFY_URL_FILE="${DOTFILES_NTFY_URL_FILE:-/etc/dotfiles/ntfy-url}"
NTFY_LIB="${DOTFILES_NTFY_LIB:-/usr/local/lib/dotfiles/ntfy.sh}"

log() {
    logger -t dotfiles-smartd -- "$*" 2> /dev/null || true
}

[ -s "$NTFY_URL_FILE" ] || exit 0
if [ ! -r "$NTFY_LIB" ]; then
    log "couldn't push the warning to ntfy: $NTFY_LIB is missing"
    exit 0
fi
# shellcheck source=lib/ntfy.sh
source "$NTFY_LIB"

subject="${SMARTD_SUBJECT:-SMART warning on $(hostname)}"
message="${SMARTD_MESSAGE:-${SMARTD_FULLMESSAGE:-smartd reported a problem with ${SMARTD_DEVICE:-a disk}}}"
# The URL holds the topic, which is its only secret, so the log leaves it out
if ! out="$(ntfy_push "$(head -n 1 "$NTFY_URL_FILE")" "$subject" "$message" \
    "Priority: urgent" "Tags: warning" 2>&1)"; then
    log "couldn't push the warning to ntfy: ${out:-curl failed}"
fi
exit 0
