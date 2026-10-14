#!/bin/bash
set -euo pipefail

# Turn on Touch ID for sudo on macOS in /etc/pam.d/sudo_local, which /etc/pam.d/sudo includes on
# macOS 14 and later, and which OS updates keep. Each run rebuilds the file from scratch
# (desired_sudo_local in macos/pam.sh): pam_tid, after pam_reattach when the homebrew step has
# installed pam-reattach, so Touch ID works inside tmux too. Any other line in sudo_local goes:
# unlike the files AGENTS.md says are never replaced, macOS reserves sudo_local for local sudo
# changes such as this one, and rebuilding it keeps status and setup in agreement.
# setup.sh doesn't run it, since it changes /etc with sudo. Idempotent: safe to re-run. --status
# reports, changing nothing.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=pam.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pam.sh"

usage() {
    echo "Usage: bash macos/setup-touch-id-sudo.sh [--status] (or: just touch-id)"
    echo "Turns on Touch ID for sudo in $SUDO_LOCAL, and in tmux with pam-reattach. macOS only."
}

write_sudo_local() {
    local tmp status=0
    tmp="$(mktemp)"
    printf '%s\n' "$1" > "$tmp"
    # Read-only and owned by root, like the rest of /etc/pam.d
    sudo install -m 444 "$tmp" "$SUDO_LOCAL" || status=$?
    rm -f "$tmp"
    return "$status"
}

status() {
    if is_macos; then
        status_touch_id missing
    else
        status_item skipped "Touch ID for sudo: macOS only"
    fi
    status_result
}

main() {
    local desired
    case "${1:-}" in
        --status)
            status
            return $?
            ;;
        -h | --help)
            usage
            return 0
            ;;
        "") ;;
        *)
            usage >&2
            return 2
            ;;
    esac
    if ! is_macos; then
        echo "Touch ID for sudo is macOS only. Nothing to do here."
        return 0
    fi
    if ! sudo_reads_sudo_local; then
        echo "$PAM_DIR/sudo doesn't include sudo_local, which macOS 14 added. Update macOS first." >&2
        return 1
    fi
    if [ -e "$SUDO_LOCAL" ] && [ ! -r "$SUDO_LOCAL" ]; then
        echo "Can't read $SUDO_LOCAL. Make it readable with: sudo chmod 444 $SUDO_LOCAL" >&2
        return 1
    fi

    echo "Touch ID for sudo ($SUDO_LOCAL):"
    if ! reattach_installed; then
        echo "  pam-reattach isn't installed, so Touch ID won't work inside tmux. The homebrew step"
        echo "  installs it; then re-run this script."
    fi
    desired="$(desired_sudo_local)"
    if [ -f "$SUDO_LOCAL" ] && [ "$desired" == "$(cat "$SUDO_LOCAL")" ]; then
        echo "  Touch ID for sudo is already on."
    else
        echo "  $SUDO_LOCAL will read:"
        printf '%s\n' "$desired" | sed 's/^/    /'
        if ! confirm "  Write it with sudo?"; then
            echo "  Left unchanged. Run this script from a terminal to write it."
        elif write_sudo_local "$desired"; then
            echo "  Wrote $SUDO_LOCAL. sudo now takes Touch ID."
        else
            echo "  Couldn't write $SUDO_LOCAL." >&2
            return 1
        fi
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
