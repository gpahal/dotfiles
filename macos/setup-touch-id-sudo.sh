#!/bin/bash
set -euo pipefail

# Turn on Touch ID for sudo on macOS in /etc/pam.d/sudo_local, which /etc/pam.d/sudo includes, and
# which OS updates keep. Each run rebuilds the file from scratch (desired_sudo_local in
# macos/pam.sh): pam_tid, after pam_reattach when the homebrew step has installed pam-reattach, so
# Touch ID works inside tmux too. sudo loads a root-owned copy of pam-reattach's module in
# /usr/local/lib/pam, which this script installs from Homebrew's and updates when it changes.
# Any other line in sudo_local goes: unlike the files AGENTS.md says are never replaced, macOS
# reserves sudo_local for local sudo changes such as this one, and rebuilding it keeps status and
# setup in agreement.
# setup.sh doesn't run it, since it changes /etc with sudo. --status reports, changing nothing.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=pam.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pam.sh"

usage() {
    echo "Usage: bash macos/setup-touch-id-sudo.sh [--status] (or: just touch-id)"
    echo "Turns on Touch ID for sudo in $SUDO_LOCAL, and in tmux with pam-reattach. macOS only."
}

# Copy Homebrew's module to the root-owned dir. Read-only, like the modules macOS ships.
install_reattach_module() {
    sudo install -d -o root -g wheel -m 755 "$PAM_LOCAL_MODULES_DIR" &&
        sudo install -o root -g wheel -m 444 "$REATTACH_SOURCE" "$REATTACH_MODULE"
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
    local desired copy=false write=false
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
    if [ -e "$SUDO_LOCAL" ] && [ ! -r "$SUDO_LOCAL" ]; then
        echo "Can't read $SUDO_LOCAL. Make it readable with: sudo chmod 444 $SUDO_LOCAL" >&2
        return 1
    fi
    read_reattach_source

    local parent
    parent="$(reattach_unsafe_parent)"
    if [ -n "$parent" ] && { [ -f "$REATTACH_MODULE" ] || reattach_source_installed; }; then
        echo "$parent, above $PAM_LOCAL_MODULES_DIR, isn't root's alone to write, so sudo can't safely load pam-reattach from there. Fix it with sudo chown root $parent && sudo chmod go-w $parent, then re-run this script." >&2
        return 1
    fi
    # Without Homebrew's module, a copy others can write can't be put right
    if [ -f "$REATTACH_MODULE" ] && ! reattach_source_installed && ! reattach_module_safe; then
        echo "$REATTACH_MODULE, which sudo loads, isn't root's alone to write. Run brew install pam-reattach, then re-run this script." >&2
        return 1
    fi

    echo "Touch ID for sudo ($SUDO_LOCAL):"
    if [ ! -f "$REATTACH_MODULE" ] && ! reattach_source_installed; then
        echo "  pam-reattach isn't installed, so Touch ID won't work inside tmux. The homebrew step"
        echo "  installs it; then re-run this script."
    fi
    desired="$(desired_sudo_local)"
    reattach_copy_needed && copy=true
    [ -f "$SUDO_LOCAL" ] && [ "$desired" == "$(cat "$SUDO_LOCAL")" ] || write=true
    if ! "$copy" && ! "$write"; then
        echo "  Touch ID for sudo is already on."
        return 0
    fi
    if "$copy"; then
        echo "  pam-reattach's module will be copied, root-owned and read-only, to $REATTACH_MODULE."
    fi
    if "$write"; then
        echo "  $SUDO_LOCAL will read:"
        printf '%s\n' "$desired" | sed 's/^/    /'
    fi
    if ! confirm "  Do it with sudo?"; then
        echo "  Left unchanged. Run this script from a terminal to do it."
        return 0
    fi
    # The copy goes first, so sudo_local never loads a module that isn't there
    if "$copy"; then
        if ! install_reattach_module; then
            echo "  Couldn't install $REATTACH_MODULE." >&2
            return 1
        fi
        echo "  Installed $REATTACH_MODULE."
    fi
    if "$write"; then
        # Read-only and owned by root, like the rest of /etc/pam.d
        if ! write_root_file "$SUDO_LOCAL" "$desired" 444; then
            echo "  Couldn't write $SUDO_LOCAL." >&2
            return 1
        fi
        echo "  Wrote $SUDO_LOCAL. sudo now takes Touch ID."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
