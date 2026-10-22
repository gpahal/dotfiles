#!/bin/bash
set -euo pipefail

# Turn on Touch ID for sudo on macOS in /etc/pam.d/sudo_local, which OS updates keep.
# Not run by setup.sh, since it changes /etc with sudo. Adds its lines and keeps yours.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=pam.sh
source "$DOTFILES_DIR/macos/pam.sh"

STEP_OS=macos

# macOS's sudo keeps your PATH, which starts with dirs you can write (~/.local/bin, mise's shims,
# Homebrew's), so sudo, and what it runs, come from the system's dirs first
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Temp name then rename, so sudo_local never names a missing module between sudo runs (which
# would break sudo). mv -h replaces a link rather than following it.
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
        # Recheck, so sudo_local never names a copy others can swap
        reason="$(pam_entry_unsafe "$REATTACH_MODULE")"
        if [ -n "$reason" ]; then
            echo "  sudo can't safely load $REATTACH_MODULE: $reason, then re-run just touch-id." >&2
            return 1
        fi
        echo "  Installed $REATTACH_MODULE."
    fi
    if "$write"; then
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
