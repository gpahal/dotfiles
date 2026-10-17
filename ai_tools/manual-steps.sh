#!/bin/bash
set -euo pipefail

# Print the AI tool steps scripts can't do on this OS, from ai_tools/README.md's Manual steps
# section, so the list has one copy. On macOS, also offer to open the settings still to do.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CLAUDE_CHROME_EXTENSION_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
NOTIFICATION_SETTINGS="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"

# Print each of the given apps whose notifications aren't allowed with the Persistent alert style,
# reading each app's entry once. Fails when the settings can't be read: macOS only lets a terminal
# with Full Disk Access read them. Flag bits as decoded by https://github.com/drewdiver/ncprefs.py:
# 1<<25 Allow notifications, 1<<3 Temporary (banners), 1<<4 Persistent (alerts).
notifications_pending() {
    local count i id flags wanted=" $* " persistent=" "
    count="$(plutil -extract apps raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || return 1
    for ((i = 0; i < count; i++)); do
        id="$(plutil -extract "apps.$i.bundle-id" raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || continue
        [[ "$wanted" == *" $id "* ]] || continue
        flags="$(plutil -extract "apps.$i.flags" raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || continue
        if (( (flags >> 25 & 1) && (flags >> 4 & 1) && !(flags >> 3 & 1) )); then
            persistent+="$id "
        fi
    done
    for id; do
        [[ "$persistent" == *" $id "* ]] || echo "$id"
    done
}

open_manual_steps() {
    local bundle_id pending_notifications="" readable=true extension_installed=false open_extension=false targets=""
    # Unreadable settings would count all four apps as pending, so don't offer to open them
    if ! pending_notifications="$(notifications_pending com.mitchellh.ghostty \
        com.anthropic.claudefordesktop com.openai.codex com.t3tools.t3code)"; then
        pending_notifications=""
        readable=false
    fi
    if compgen -G "$HOME/Library/Application Support/Google/Chrome/*/Extensions/$CLAUDE_CHROME_EXTENSION_ID" > /dev/null; then
        extension_installed=true
    elif [ -d "/Applications/Google Chrome.app" ]; then
        open_extension=true
    fi

    print_section macOS
    if ! "$readable"; then
        echo "  Couldn't read the notification settings, which macOS lets only a terminal with Full Disk Access read."
        echo "  In System Settings → Notifications, set Ghostty, Claude, ChatGPT, and T3 Code to Allow notifications + Persistent."
    elif [ -z "$pending_notifications" ]; then
        echo "  Notifications for Ghostty, Claude, ChatGPT, and T3 Code are already allowed and Persistent."
    fi
    if "$extension_installed"; then
        echo "  Claude in Chrome extension already installed."
    fi

    # Only offer to open what still needs doing. DOTFILES_ASSUME_YES runs on a test machine, where
    # nobody is there to set anything.
    [ -n "$pending_notifications" ] && targets="the notification settings"
    "$open_extension" && targets="${targets:+$targets and }the Chrome extension page"
    [ -n "$targets" ] || return 0
    if [ "${DOTFILES_ASSUME_YES:-}" == 1 ]; then
        echo "  Not opening $targets: DOTFILES_ASSUME_YES is set."
        return 0
    fi
    confirm "Open $targets now?" || return 0

    for bundle_id in $pending_notifications; do
        open "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=$bundle_id"
        read -r -p "  Set $bundle_id to Allow notifications + Persistent, then press Enter..." _
    done

    if "$open_extension"; then
        open -a "Google Chrome" "https://chromewebstore.google.com/detail/claude/$CLAUDE_CHROME_EXTENSION_ID"
    fi

    if [ -n "$pending_notifications" ]; then
        echo "  Test a notification from your terminal with: $DOTFILES_DIR/scripts/test-notification.sh"
    fi
}

print_section() {
    echo ""
    echo "Remaining AI tool steps on $1 (ai_tools/README.md → Manual steps):"
    print_doc_section "$DOTFILES_DIR/ai_tools/README.md" "## Manual steps" "### $1"
}

main() {
    step_args "$@"
    # Nothing to check: the list is what scripts can't do
    ! status_requested "$@" || return 0
    if is_macos; then
        open_manual_steps
    else
        print_section Ubuntu
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
