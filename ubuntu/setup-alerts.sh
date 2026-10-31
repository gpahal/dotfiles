#!/bin/bash
set -euo pipefail

# Point the alerts at this machine's ntfy server and send a test push; --test fires the hooks.
# The token is this machine's own, from the client config just ntfy-user writes, so nothing is
# typed, and it's never an argument.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=lib/ntfy.sh
source "$DOTFILES_DIR/ubuntu/lib/ntfy.sh"
# shellcheck source=lib/paths.sh
source "$DOTFILES_DIR/ubuntu/lib/paths.sh"
# shellcheck source=lib/alerts.sh
source "$DOTFILES_DIR/ubuntu/lib/alerts.sh"
# shellcheck source=../ntfy/lib/server.sh
source "$DOTFILES_DIR/ntfy/lib/server.sh"
# shellcheck source=../ntfy/lib/client.sh
source "$DOTFILES_DIR/ntfy/lib/client.sh"

usage() {
    echo "Usage: bash ubuntu/setup-alerts.sh [--test] (or: just alerts [test])"
    echo "Points the four alerts, smartd's disk warnings, the UPS's events, the daily health alert,"
    echo "and the boot notice, at this machine's ntfy server ($NTFY_ALERTS_URL). It saves the URL"
    echo "and this machine's token, from the client config just ntfy-user writes, in files only you,"
    echo "nut, and root can read, shows how to subscribe on Android, and sends a test push. --test runs"
    echo "the disk warning hook and the UPS notifier with test events. Ubuntu only."
}

current_url() {
    head -n 1 "$NTFY_URL_FILE" 2> /dev/null || true
}

current_token() {
    head -n 1 "$NTFY_TOKEN_FILE" 2> /dev/null || true
}

saved() {
    [ "$(current_url)" == "$NTFY_ALERTS_URL" ] && [ "$(current_token)" == "$1" ] &&
        [ -z "$(alerts_file_problem "$NTFY_URL_FILE")" ] && [ -z "$(alerts_file_problem "$NTFY_TOKEN_FILE")" ]
}

save() {
    write_root_file "$NTFY_URL_FILE" "$NTFY_ALERTS_URL" 0640 "$(ntfy_url_group)" "$CURRENT_USER" &&
        write_root_file "$NTFY_TOKEN_FILE" "$1" 0640 "$(ntfy_url_group)" "$CURRENT_USER"
}

# The Android app opens only ntfy:// links. It keeps the port and defaults to https, but a link has
# no password, and the app matches users by the exact server URL, so the user goes in first.
show_subscribe_links() {
    local base="$1" topic display
    echo "  To subscribe on Android, first add your user for $base in the ntfy app (Settings →"
    echo "  Manage users), then scan each code, or add the topic with \"Use another server\":"
    for topic in "${NTFY_TOPICS[@]}"; do
        display="$(tr '[:lower:]' '[:upper:]' <<< "${topic:0:1}")${topic:1}"
        echo "  $display: $base/$topic"
        if command -v qrencode &> /dev/null; then
            qrencode -t ANSIUTF8 "ntfy://${base#https://}/$topic?display=$display"
        fi
    done
    command -v qrencode &> /dev/null ||
        echo "  bash setup.sh ubuntu installs qrencode, which shows these as QR codes to scan."
}

send_test_push() {
    ntfy_push "$NTFY_ALERTS_URL" "Alerts from $(hostname)" \
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
    echo "  Done. The warning shows on your phone."
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
    echo "  Done. The UPS test shows on your phone."
    echo "  When one doesn't arrive, journalctl -t dotfiles-ups says why."
}

main() {
    local token base status=0
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
        if [ ! -s "$NTFY_URL_FILE" ]; then
            echo "The alerts aren't set up, so a test would only fail. Run just ntfy-user first." >&2
            return 1
        fi
        run_test_warning || status=$?
        run_test_ups || status=1
        return "$status"
    fi
    require_cmd curl || return 1
    require_cmd jq || return 1
    if ! ntfy_healthy; then
        echo "This machine's ntfy server doesn't answer on $NTFY_LOCAL_URL. Run bash setup.sh ntfy first." >&2
        return 1
    fi
    token="$(ntfy_client_token)"
    if [ -z "$token" ]; then
        echo "No token in $(ntfy_client_config) yet. Run just ntfy-user first, which runs this too." >&2
        return 1
    fi
    # The phone reaches the server through Tailscale Funnel
    base="$(ntfy_public_url)" || base=""
    [ -x "$SMARTD_HOOK" ] || echo "The warning hook isn't installed yet; bash setup.sh ubuntu installs it."
    echo "Disk, UPS, health, and boot alerts ($NTFY_URL_FILE and $NTFY_TOKEN_FILE):"
    if saved "$token"; then
        echo "  Already sent to $NTFY_ALERTS_URL. just alerts test sends test events."
        [ -z "$base" ] || show_subscribe_links "$base"
        return 0
    fi
    if ! confirm "  Send them to $NTFY_ALERTS_URL with this machine's token, saved with sudo?"; then
        left_unchanged "  " "just alerts" "save them"
        return 0
    fi
    if ! save "$token"; then
        echo "  Couldn't write $NTFY_URL_FILE and $NTFY_TOKEN_FILE." >&2
        return 1
    fi
    echo "  Saved."
    [ -z "$base" ] || show_subscribe_links "$base"
    if send_test_push; then
        echo "  Sent a test push to the alerts topic. Check that it reached your phone."
    else
        echo "  The test push failed. Check that ntfy runs (bash setup.sh --status ntfy), then run just alerts." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
