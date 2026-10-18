#!/bin/bash
set -euo pipefail

# The health alerts the ubuntu step's user units run, pushed to the ntfy topic whose URL
# bash ubuntu/setup-alerts.sh saves in /etc/dotfiles/ntfy-url. With no URL saved, they do
# nothing.
#   status  run bash setup.sh --status --quick and bash ai_tools/setup.sh --status --quick, and
#           when one exits 1 (a step failed) or 3 (something needs attention), push its "Needs
#           attention" and "Failed steps" lines and its missing and unknown items
#           (dotfiles-health.timer, daily). It pushes again when the message changes (ignoring
#           digits) or a week has passed, and pushes "All clear" once when nothing needs attention;
#           $HEALTH_STATE_FILE records the last push. sudo's cached credentials don't reach a user
#           service, so the checks only root can make come back unverified here, which needs no
#           attention; a push that has them ends with $ROOT_ONLY_NOTE.
#   boot    push "<host> started at <time>", so an unexpected reboot gets noticed
#           (dotfiles-boot-notice.service)
# Ubuntu only. It fails when a runner couldn't run or a push failed, so the unit shows failed.

HEALTH_REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ntfy.sh
source "$HEALTH_REPO_DIR/ubuntu/lib/ntfy.sh"

# Tests point this into their sandbox
NTFY_URL_FILE="${DOTFILES_NTFY_URL_FILE:-/etc/dotfiles/ntfy-url}"
# ntfy turns a message over 4096 bytes into an attachment, so this leaves room for ROOT_ONLY_NOTE
MESSAGE_MAX_BYTES=3500
# How a status item only root could check says so, and the line a push then ends with
ROOT_ONLY_PATTERN='^  unverified .*run sudo -v, then status'
ROOT_ONLY_NOTE="Not checked here, since they need root: ufw's rules, sshd's effective settings, SMART health, and NUT's and Docker's config files. Run sudo -v, then just status, to check them."
# "<epoch seconds of the last push> <cksum of the message pushed, or clear>"
HEALTH_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/health-alert"
# An unchanged message is pushed again after this many seconds (a week)
REPUSH_SECONDS=604800
# The network may come up after the user manager starts the boot notice. The tries, each up to
# ntfy_push's 10s curl --max-time plus the wait, must fit the unit's TimeoutStartSec=10min (see
# health_unit in lib/alerts.sh): 20 * (10 + 10) = 400s.
BOOT_ATTEMPTS=20
BOOT_RETRY_SECONDS=10

usage() {
    echo "Usage: bash ubuntu/health-alert.sh status | boot"
    echo "status pushes what setup's --status --quick reports needs attention to ntfy; boot pushes"
    echo "that this machine started. Both do nothing until just alerts saves a URL."
}

# Print the saved URL. Fails, saying why, when the file is there but unreadable.
ntfy_url() {
    [ -e "$NTFY_URL_FILE" ] || return 0
    if [ ! -r "$NTFY_URL_FILE" ]; then
        echo "Can't read $NTFY_URL_FILE. Save the URL again with just alerts." >&2
        return 1
    fi
    head -n 1 "$NTFY_URL_FILE"
}

# Print the lines of a runner's --status output that need attention: the summary lines, then each
# missing or unknown item as "<step>: <item>", from run_steps' "<step>:" headers
attention_lines() {
    awk '
        /^(Needs attention|Failed steps):/ { summary = summary $0 "\n"; next }
        /^[^ ].*:$/ { step = substr($0, 1, length($0) - 1); next }
        /^  (missing|unknown) / { sub(/^  [a-z]+ +/, ""); items = items (step == "" ? "" : step ": ") $0 "\n" }
        END { printf "%s%s", summary, items }
    '
}

# Print the first lines of stdin that fit in MESSAGE_MAX_BYTES, and a note when some didn't
truncate_message() {
    LC_ALL=C awk -v max="$MESSAGE_MAX_BYTES" '
        { n++ }
        !full && size + length($0) + 1 <= max { out = out $0 "\n"; size += length($0) + 1; next }
        { full = 1; left++ }
        END {
            printf "%s", out
            if (left) printf "...and %d more lines; bash setup.sh --status lists them\n", left
        }
    '
}

# Print a date given in epoch seconds. GNU and Rust date take -d @<seconds>, BSD date -r.
format_epoch() {
    date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M %Z'
}

# Record a push as "<now> <hash>". A failed write only warns: the push went out, and the next run
# pushes again.
save_push() {
    { mkdir -p "$(dirname "$HEALTH_STATE_FILE")" &&
        printf '%s %s\n' "$1" "$2" > "$HEALTH_STATE_FILE"; } 2>/dev/null ||
        echo "Couldn't save the last push to $HEALTH_STATE_FILE." >&2
}

status_alert() {
    local url runner out status result=0 message="" now last_time="" last_hash="" hash root_only=false
    url="$(ntfy_url)" || return 1
    [ -n "$url" ] || return 0
    for runner in setup.sh ai_tools/setup.sh; do
        status=0
        out="$("$BASH" "$HEALTH_REPO_DIR/$runner" --status --quick < /dev/null 2>&1)" || status=$?
        ! grep -qE "$ROOT_ONLY_PATTERN" <<< "$out" || root_only=true
        case "$status" in
            0) ;;
            1 | 3) message="$message$(attention_lines <<< "$out")"$'\n' ;;
            *)
                echo "$runner --status --quick exited $status:" >&2
                printf '%s\n' "$out" | tail -n 5 >&2
                result=1
                ;;
        esac
    done
    now="$(date +%s)"
    # A missing or unreadable state file counts as never pushed
    read -r last_time last_hash 2>/dev/null < "$HEALTH_STATE_FILE" || true
    case "$last_time" in '' | *[!0-9]*) last_time="" last_hash="" ;; esac
    if [ -z "$message" ]; then
        [ "$result" -eq 0 ] || return "$result"
        # Never pushed, or the last push was the all-clear: nothing to clear
        if [ -z "$last_hash" ] || [ "$last_hash" == clear ]; then
            echo "Nothing needs attention."
            return 0
        fi
        if ! ntfy_push "$url" "All clear on $(hostname)" "Nothing needs attention any more." \
            "Tags: white_check_mark"; then
            echo "Couldn't push the all-clear to ntfy." >&2
            return 1
        fi
        save_push "$now" clear
        echo "Pushed that nothing needs attention any more to ntfy."
        return 0
    fi
    message="$(truncate_message <<< "$message")"
    ! "$root_only" || message="$message"$'\n'"$ROOT_ONLY_NOTE"
    # Without the digits, so a measured value that moves, such as free disk space, isn't a change
    hash="$(printf '%s' "$message" | tr -d '0-9' | cksum | awk '{ print $1 }')"
    if [ "$hash" == "$last_hash" ] && [ $((now - last_time)) -lt "$REPUSH_SECONDS" ]; then
        echo "Unchanged since the last push on $(format_epoch "$last_time"); not pushing again until $(format_epoch $((last_time + REPUSH_SECONDS)))."
        return "$result"
    fi
    if ! ntfy_push "$url" "Needs attention on $(hostname)" "$message" "Tags: warning"; then
        echo "Couldn't push the health alert to ntfy." >&2
        return 1
    fi
    save_push "$now" "$hash"
    echo "Pushed what needs attention to ntfy."
    return "$result"
}

boot_notice() {
    local url attempt=1 host
    url="$(ntfy_url)" || return 1
    [ -n "$url" ] || return 0
    host="$(hostname)"
    while ! ntfy_push "$url" "$host started" "$host started at $(date '+%Y-%m-%d %H:%M %Z')." \
        "Tags: arrows_counterclockwise"; do
        if [ "$attempt" -ge "$BOOT_ATTEMPTS" ]; then
            echo "Couldn't push the boot notice to ntfy after $BOOT_ATTEMPTS tries." >&2
            return 1
        fi
        attempt=$((attempt + 1))
        sleep "$BOOT_RETRY_SECONDS"
    done
    echo "Pushed the boot notice to ntfy."
}

main() {
    case "${1:-}" in
        status) status_alert ;;
        boot) boot_notice ;;
        -h | --help) usage ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
