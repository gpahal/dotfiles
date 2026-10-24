#!/bin/bash
set -euo pipefail

# Pushes health alerts to ntfy for the ubuntu step's user units; does nothing with no URL saved.
# Fails when a runner couldn't run or a push failed, so the unit shows failed.

# The ubuntu step copies this script beside its three libraries, outside the repo
HEALTH_ALERT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ntfy.sh
source "$HEALTH_ALERT_DIR/ntfy.sh"
# shellcheck source=lib/paths.sh
source "$HEALTH_ALERT_DIR/paths.sh"
# shellcheck source=../lib/status-format.sh
source "$HEALTH_ALERT_DIR/status-format.sh"

NTFY_URL_FILE="${DOTFILES_NTFY_URL_FILE:-$NTFY_URL_FILE}"
# ntfy turns a message over 4096 bytes into an attachment; leaves room for ROOT_ONLY_NOTE
MESSAGE_MAX_BYTES=3500
ROOT_ONLY_NOTE="Not checked here, since they need root: ufw's rules, sshd's effective settings, SMART health, NUT's and Docker's config files, and unattended-upgrades' settings when only root can read them. Run sudo -v, then just status, to check them."
# "<epoch of last push> <cksum of message, or clear>"
HEALTH_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/health-alert"
REPUSH_SECONDS=604800
# The network may come up late. 20 * (10s curl timeout + 10s wait) must fit the unit's
# TimeoutStartSec=10min (systemd/dotfiles-boot-notice.service).
BOOT_ATTEMPTS=20
BOOT_RETRY_SECONDS=10
BOOT_ID_FILE="${DOTFILES_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
BOOT_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/boot-notice"

usage() {
    echo "Usage: bash health-alert.sh status | boot"
    echo "status pushes what setup.sh and ai_tools/setup.sh --status --for-alerts, run in $DOTFILES_REPO,"
    echo "report needs attention to ntfy; boot pushes that this machine started. Both do nothing until just alerts"
    echo "saves a URL."
}

ntfy_url() {
    [ -e "$NTFY_URL_FILE" ] || return 0
    if [ ! -r "$NTFY_URL_FILE" ]; then
        echo "Can't read $NTFY_URL_FILE. Save the URL again with just alerts." >&2
        return 1
    fi
    head -n 1 "$NTFY_URL_FILE"
}

attention_lines() {
    local line step="" summary="" items=""
    while IFS= read -r line || [ -n "$line" ]; do
        if status_summary_line "$line"; then
            summary="$summary$line"$'\n'
        elif status_parse_line "$line"; then
            ! status_state_needs_attention "$STATUS_LINE_STATE" ||
                items="$items${step:+$step: }$STATUS_LINE_TEXT"$'\n'
        elif [[ "$line" == [!\ ]*: ]]; then
            step="${line%:}"
        fi
    done
    printf '%s%s' "$summary" "$items"
}

has_root_only_items() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if status_parse_line "$line" && [ "$STATUS_LINE_STATE" == unverified ] &&
            [[ "$STATUS_LINE_TEXT" == *"$ROOT_ONLY_TEXT"* ]]; then
            return 0
        fi
    done
    return 1
}

truncate_message() {
    LC_ALL=C awk -v max="$MESSAGE_MAX_BYTES" '
        !full && size + length($0) + 1 <= max { out = out $0 "\n"; size += length($0) + 1; next }
        { full = 1; left++ }
        END {
            printf "%s", out
            if (left) printf "...and %d more lines; bash setup.sh --status lists them\n", left
        }
    '
}

# GNU and Rust date take -d @<seconds>, BSD date -r
format_epoch() {
    date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M %Z'
}

# A failed write only warns: the push went out
save_push() {
    { mkdir -p "$(dirname "$HEALTH_STATE_FILE")" &&
        printf '%s %s\n' "$1" "$2" > "$HEALTH_STATE_FILE"; } 2>/dev/null ||
        echo "Couldn't save the last push to $HEALTH_STATE_FILE." >&2
}

status_alert() {
    local url runner out status result=0 message="" details="" last now last_time="" last_hash="" hash
    local root_only=false
    url="$(ntfy_url)" || return 1
    [ -n "$url" ] || return 0
    if [ ! -e "$DOTFILES_REPO/setup.sh" ]; then
        echo "No repo at $DOTFILES_REPO, so the health check couldn't run." >&2
        ntfy_push "$url" "Needs attention on $(hostname)" "Health check couldn't run: no repo at $DOTFILES_REPO" \
            "Tags: warning" || echo "Couldn't push the health alert to ntfy." >&2
        return 1
    fi
    for runner in setup.sh ai_tools/setup.sh; do
        status=0
        out="$("$BASH" "$DOTFILES_REPO/$runner" --status --for-alerts < /dev/null 2>&1)" || status=$?
        ! has_root_only_items <<< "$out" || root_only=true
        case "$status" in
            0) ;;
            1 | 3) message="$message$(attention_lines <<< "$out")"$'\n' ;;
            *)
                echo "$runner --status --for-alerts exited $status:" >&2
                printf '%s\n' "$out" | tail -n 5 >&2
                # The last line goes in details, not the hash, since it can change each run
                message="${message}Health check couldn't run: $runner exited $status"$'\n'
                last="$(grep -v '^[[:space:]]*$' <<< "$out" | tail -n 1)" || last=""
                [ -z "$last" ] || details="$details"$'\n'"$runner's last output: $last"
                result=1
                ;;
        esac
    done
    now="$(date +%s)"
    read -r last_time last_hash 2>/dev/null < "$HEALTH_STATE_FILE" || true
    case "$last_time" in '' | *[!0-9]*) last_time="" last_hash="" ;; esac
    if [ -z "$message" ]; then
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
    # Digits dropped so a moving value, such as free disk space, isn't a change
    hash="$(printf '%s' "$message" | tr -d '0-9' | cksum | awk '{ print $1 }')"
    if [ "$hash" == "$last_hash" ] && [ $((now - last_time)) -lt "$REPUSH_SECONDS" ]; then
        echo "Unchanged since the last push on $(format_epoch "$last_time"); not pushing again until $(format_epoch $((last_time + REPUSH_SECONDS)))."
        return "$result"
    fi
    [ -z "$details" ] || message="$message"$'\n'"$details"
    if ! ntfy_push "$url" "Needs attention on $(hostname)" "$message" "Tags: warning"; then
        echo "Couldn't push the health alert to ntfy." >&2
        return 1
    fi
    save_push "$now" "$hash"
    echo "Pushed what needs attention to ntfy."
    return "$result"
}

boot_notice() {
    local url attempt=1 host boot_id="" last=""
    url="$(ntfy_url)" || return 1
    [ -n "$url" ] || return 0
    # The user manager can restart within a boot; without a boot ID, every start pushes
    boot_id="$(cat "$BOOT_ID_FILE" 2>/dev/null)" || boot_id=""
    last="$(cat "$BOOT_STATE_FILE" 2>/dev/null)" || last=""
    if [ -n "$boot_id" ] && [ "$boot_id" == "$last" ]; then
        echo "Already pushed the boot notice for this boot."
        return 0
    fi
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
    [ -z "$boot_id" ] || { mkdir -p "$(dirname "$BOOT_STATE_FILE")" &&
        printf '%s\n' "$boot_id" > "$BOOT_STATE_FILE"; } 2>/dev/null ||
        echo "Couldn't save the boot's ID to $BOOT_STATE_FILE." >&2
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
