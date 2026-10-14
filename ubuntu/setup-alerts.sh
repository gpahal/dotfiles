#!/bin/bash
set -euo pipefail

# Push the alerts to a phone through ntfy: smartd's disk warnings, the UPS's events, the daily
# health alert, and the boot notice. Save a topic's URL in /etc/dotfiles/ntfy-url, which the hooks
# the ubuntu step installs (ubuntu/smartd-notify.sh and ubuntu/ups-notify.sh) and
# ubuntu/health-alert.sh read, and send a test push.
# --test runs the installed smartd hook with a made-up warning, and the UPS notifier, when a UPS is
# set up, with a test event, which they push to ntfy. The topic is yours to pick, so setup.sh
# doesn't run this. Idempotent: safe to re-run.
# Ubuntu only.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/ntfy.sh
source "$DOTFILES_DIR/ubuntu/lib/ntfy.sh"

# The ubuntu step's SMARTD_HOOK, UPS_NOTIFY, and NTFY_URL_FILE
SMARTD_HOOK=/etc/smartmontools/run.d/50dotfiles-notify
UPS_NOTIFY=/usr/local/libexec/dotfiles-ups-notify
NTFY_URL_FILE=/etc/dotfiles/ntfy-url

usage() {
    echo "Usage: bash ubuntu/setup-alerts.sh <ntfy-url> | --test (or: just alerts <ntfy-url> | test)"
    echo "Saves the ntfy topic URL in $NTFY_URL_FILE, and sends a test push. Four alerts go there:"
    echo "smartd's disk warnings, the UPS's events, the daily health alert, and the boot notice."
    echo "--test runs the disk warning hook and the UPS notifier with test events. Ubuntu only."
}

# Prints nothing when the file is missing or unreadable
current_url() {
    head -n 1 "$NTFY_URL_FILE" 2> /dev/null || true
}

# Root owns the file, and every user may read it, so the health alerts, which run as you, can. The
# machine has one login user, and the topic's secrecy matters off the machine.
save_url() {
    sudo mkdir -p "$(dirname "$NTFY_URL_FILE")" &&
        sudo chmod 755 "$(dirname "$NTFY_URL_FILE")" &&
        printf '%s\n' "$1" | sudo sh -c 'umask 022 && cat > "$1" && chmod 644 "$1"' sh "$NTFY_URL_FILE"
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

# Run the UPS notifier as upsmon does, as the nut user. It always exits 0, so its status says
# nothing about the push.
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
    local url status=0
    case "${1:-}" in
        -h | --help)
            usage
            return 0
            ;;
        "")
            usage >&2
            return 2
            ;;
    esac
    if [ $# -gt 1 ]; then
        usage >&2
        return 2
    fi
    if ! is_ubuntu; then
        echo "The alerts are Ubuntu only. Nothing to do here."
        return 0
    fi
    if [ "$1" == --test ]; then
        run_test_warning || status=$?
        run_test_ups || status=1
        return "$status"
    fi
    url="$1"
    if ! [[ "$url" =~ ^https://[^[:space:]/]+/[^[:space:]]+$ ]]; then
        echo "Not an https ntfy topic URL: $url. Give one such as https://ntfy.sh/<topic>." >&2
        return 2
    fi
    require_cmd curl || return 1
    [ -x "$SMARTD_HOOK" ] || echo "The warning hook isn't installed yet; bash setup.sh ubuntu installs it."
    echo "ntfy URL for the disk, UPS, health, and boot alerts ($NTFY_URL_FILE):"
    if [ "$(current_url)" == "$url" ]; then
        echo "  Already set. just alerts test sends a test warning."
        return 0
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
        echo "  The test push failed. Check the URL, then run just alerts test." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
