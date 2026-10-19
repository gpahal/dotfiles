#!/bin/bash
set -euo pipefail

# Turn on Touch ID for sudo on macOS in /etc/pam.d/sudo_local, which OS updates keep.
#
# Each run rebuilds the file from scratch (desired_sudo_local in macos/pam.sh), dropping any other
# line, which keeps status and setup in agreement. sudo loads a root-owned copy of pam-reattach's
# module in /usr/local/lib/pam, which this script installs from Homebrew's and updates.
# setup.sh doesn't run it, since it changes /etc with sudo. --status reports, changing nothing.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"
# shellcheck source=pam.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pam.sh"

STEP_OS=macos

# Copy Homebrew's module to the root-owned dir, read-only like the modules macOS ships. It goes in
# under a temp name that mv then renames over the copy, so between the sudo runs sudo_local never
# names a missing module, which would keep the next sudo from starting PAM. The rename replaces a
# link in the copy's place rather than writing through it, and -h keeps mv from following one to a
# dir.
install_reattach_module() {
    sudo install -d -o root -g wheel -m 755 "$PAM_LOCAL_MODULES_DIR" &&
        sudo install -o root -g wheel -m 444 "$REATTACH_SOURCE" "$REATTACH_MODULE.new" &&
        sudo mv -fh "$REATTACH_MODULE.new" "$REATTACH_MODULE"
}

status() {
    status_touch_id missing
    status_result
}

apply() {
    local desired copy=false write=false blocker reason pending=()
    if [ -e "$SUDO_LOCAL" ] && [ ! -r "$SUDO_LOCAL" ]; then
        echo "Can't read $SUDO_LOCAL. Make it readable with: sudo chmod 444 $SUDO_LOCAL" >&2
        return 1
    fi
    if blocker="$(reattach_blocker)"; then
        echo "Touch ID in tmux: $blocker." >&2
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
        pending+=("Copy pam-reattach's module, root-owned and read-only, to $REATTACH_MODULE")
    fi
    if "$write"; then
        echo "  $SUDO_LOCAL will read:"
        printf '%s\n' "$desired" | sed 's/^/    /'
        pending+=("Write $SUDO_LOCAL as shown above")
    fi
    confirm_sudo_changes "${pending[@]}" || return 0
    # The copy goes first, so sudo_local never loads a module that isn't there
    if "$copy"; then
        if ! install_reattach_module; then
            echo "  Couldn't install $REATTACH_MODULE." >&2
            return 1
        fi
        # Checked again, so sudo_local never names a copy others can swap. The dir and its parents
        # passed reattach_blocker.
        reason="$(pam_entry_unsafe "$REATTACH_MODULE")"
        if [ -n "$reason" ]; then
            echo "  sudo can't safely load $REATTACH_MODULE: $reason, then re-run just touch-id." >&2
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
