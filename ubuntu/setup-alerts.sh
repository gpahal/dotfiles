#!/bin/bash
set -euo pipefail

# Saves a ntfy topic URL for the alerts and sends a test push; --test fires the hooks.
# The topic is the URL's only secret, so it's read from the terminal, never an argument, and it
# must be long enough that nobody guesses it.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"
# shellcheck source=lib/ntfy.sh
source "$DOTFILES_DIR/ubuntu/lib/ntfy.sh"
# shellcheck source=lib/paths.sh
source "$DOTFILES_DIR/ubuntu/lib/paths.sh"
# shellcheck source=lib/alerts.sh
source "$DOTFILES_DIR/ubuntu/lib/alerts.sh"

usage() {
    echo "Usage: bash ubuntu/setup-alerts.sh [--test] (or: just alerts [test])"
    echo "Asks for a ntfy topic name (on ntfy.sh) or a topic's https URL, or offers to generate a"
    echo "topic, saves the URL in $NTFY_URL_FILE, and sends a test push. Four alerts go there:"
    echo "smartd's disk warnings, the UPS's events, the daily health alert, and the boot notice."
    echo "Anyone who knows the topic can read and send the alerts, so it needs $NTFY_TOPIC_MIN to 64"
    echo "characters, is read from the terminal rather than taken as an argument, which any local user"
    echo "can see, and only you, nut, and root can read the file. --test runs the disk warning hook"
    echo "and the UPS notifier with test events. Ubuntu only."
}

read_topic() {
    local input=""
    if [ -t 0 ]; then
        read -rs -p "ntfy topic or URL (hidden; leave empty to generate a topic): " input || true
        echo >&2
    else
        read -r input || true
    fi
    input="${input#"${input%%[![:space:]]*}"}"
    printf '%s' "${input%"${input##*[![:space:]]}"}"
}

# Returns 2 for a topic too short or too long
topic_url() {
    local url
    if [[ "$1" =~ ^https://[^[:space:]/]+/[A-Za-z0-9_-]+$ ]]; then
        url="$1"
    elif [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; then
        url="https://ntfy.sh/$1"
    else
        return 1
    fi
    ntfy_topic_ok "${url##*/}" || return 2
    printf '%s' "$url"
}

# 32 hex characters, as nut_password makes
random_topic() {
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
}

# Shows the topic as QR codes for the phone to scan: the Android app opens only ntfy:// links
show_topic() {
    local host="${1#https://}" topic="${1##*/}"
    host="${host%%/*}"
    echo "  Topic: $topic"
    if ! command -v qrencode &>/dev/null; then
        echo "  bash setup.sh ubuntu installs qrencode, which shows the topic as QR codes to scan."
        return 0
    fi
    echo "  Android, in the ntfy app (ntfy://$host/$topic):"
    qrencode -t ANSIUTF8 "ntfy://$host/$topic"
    echo "  iPhone or a browser (https://$host/$topic):"
    qrencode -t ANSIUTF8 "https://$host/$topic"
}

current_url() {
    head -n 1 "$NTFY_URL_FILE" 2> /dev/null || true
}

save_url() {
    write_root_file "$NTFY_URL_FILE" "$1" 0640 "$(ntfy_url_group)" "$(id -un)"
}

send_test_push() {
    ntfy_push "$1" "Alerts from $(hostname)" \
        "Disk warnings, UPS events, the daily health alert, and the boot notice from $(hostname) will arrive here." \
        "Tags: white_check_mark"
}

# sudo resets the environment, so the variables go through env
run_test_warning() {
    if [ ! -x "$SMARTD_HOOK" ]; then
        echo "The warning hook, $SMARTD_HOOK, isn't installed. Run bash setup.sh ubuntu first." >&2
        return 1
    fi
    echo "Running $SMARTD_HOOK with a test warning..."
    sudo env SMARTD_SUBJECT="Test: SMART warning on $(hostname)" \
        SMARTD_MESSAGE="A test of smartd's warning hook. No disk has a problem." \
        SMARTD_DEVICE=/dev/test SMARTD_FAILTYPE=EmailTest "$SMARTD_HOOK" || return 1
    echo "  Done. The warning shows on your phone if a ntfy URL is set."
    echo "  When one doesn't arrive, journalctl -t dotfiles-smartd says why."
}

# The notifier always exits 0, so its status says nothing about the push
run_test_ups() {
    if [ ! -x "$UPS_NOTIFY" ] || ! id nut &>/dev/null; then
        echo "The UPS notifier isn't installed (no UPS set up yet); skipping its test."
        return 0
    fi
    echo "Running $UPS_NOTIFY with a test event..."
    sudo -u nut env NOTIFYTYPE=TEST UPSNAME=test "$UPS_NOTIFY" \
        "Test: a UPS event from $(hostname). The UPS is fine." || return 1
    echo "  Done. The UPS test shows on your phone if a ntfy URL is set."
    echo "  When one doesn't arrive, journalctl -t dotfiles-ups says why."
}

main() {
    local input url status=0 generated=false
    case "$#:${1:-}" in
        1:-h | 1:--help)
            usage
            return 0
            ;;
        0: | 1:--test) ;;
        *)
            usage >&2
            return 2
            ;;
    esac
    if ! is_ubuntu; then
        echo "The alerts are Ubuntu only. Nothing to do here."
        return 0
    fi
    if [ $# -eq 1 ]; then
        run_test_warning || status=$?
        run_test_ups || status=1
        return "$status"
    fi
    input="$(read_topic)"
    if [ -z "$input" ] && confirm "Generate a random topic?"; then
        input="$(random_topic)" || return 1
        generated=true
    fi
    url="$(topic_url "$input")" || status=$?
    case "$status" in
        0) ;;
        2)
            echo "A topic needs $NTFY_TOPIC_MIN to 64 characters, since anyone who knows it can read and send" >&2
            echo "your alerts. Leave it empty to generate one." >&2
            return 2
            ;;
        *)
            echo "Not a ntfy topic name or https topic URL." >&2
            return 2
            ;;
    esac
    require_cmd curl || return 1
    [ -x "$SMARTD_HOOK" ] || echo "The warning hook isn't installed yet; bash setup.sh ubuntu installs it."
    echo "ntfy URL for the disk, UPS, health, and boot alerts ($NTFY_URL_FILE):"
    if [ "$(current_url)" == "$url" ] && [ -z "$(ntfy_url_file_problem)" ]; then
        echo "  Already set. just alerts test sends a test warning."
        return 0
    fi
    if "$generated"; then
        show_topic "$url"
        echo "  Subscribe your phone to it now; the test push goes there once it's saved."
    fi
    if ! confirm "  Save it with sudo?"; then
        echo "  Left unchanged. Run this script from a terminal to save it."
        return 0
    fi
    if ! save_url "$url"; then
        echo "  Couldn't write $NTFY_URL_FILE." >&2
        return 1
    fi
    echo "  Saved."
    if send_test_push "$url"; then
        echo "  Sent a test push. Check that it reached your phone."
    else
        echo "  The test push failed. Check the topic, then run just alerts test." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
