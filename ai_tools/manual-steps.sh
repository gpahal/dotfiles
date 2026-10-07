#!/bin/bash
set -euo pipefail

# List the AI tool settings macOS doesn't let scripts change, and offer to open the ones still
# to do.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CLAUDE_CHROME_EXTENSION_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
NOTIFICATION_SETTINGS="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"

# Succeeds when an app's notifications are allowed with the Persistent alert style. Fails when
# they aren't, or when the settings can't be read: macOS only lets a terminal with Full Disk
# Access read them. Flag bits as decoded by https://github.com/drewdiver/ncprefs.py:
# 1<<25 Allow notifications, 1<<3 Temporary (banners), 1<<4 Persistent (alerts).
notifications_persistent() {
    local bundle_id="$1" count i flags
    count="$(plutil -extract apps raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || return 1
    for ((i = 0; i < count; i++)); do
        [ "$(plutil -extract "apps.$i.bundle-id" raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" == "$bundle_id" ] || continue
        flags="$(plutil -extract "apps.$i.flags" raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || return 1
        return $(( (flags >> 25 & 1) && (flags >> 4 & 1) && !(flags >> 3 & 1) ? 0 : 1 ))
    done
    return 1
}

open_manual_steps() {
    local bundle_id pending_notifications="" extension_installed=false open_extension=false targets=""
    for bundle_id in com.mitchellh.ghostty com.anthropic.claudefordesktop com.openai.codex com.t3tools.t3code; do
        notifications_persistent "$bundle_id" || pending_notifications+=" $bundle_id"
    done
    if compgen -G "$HOME/Library/Application Support/Google/Chrome/*/Extensions/$CLAUDE_CHROME_EXTENSION_ID" > /dev/null; then
        extension_installed=true
    elif [ -d "/Applications/Google Chrome.app" ]; then
        open_extension=true
    fi

    echo ""
    echo "Remaining manual steps (macOS doesn't let scripts change these):"
    if [ -n "$pending_notifications" ]; then
        echo "  1. System Settings → Notifications → Ghostty (and any other terminal you use), Claude,"
        echo "     ChatGPT, T3 Code: turn on Allow notifications and set the alert style to Persistent."
    else
        echo "  1. System Settings → Notifications: Ghostty, Claude, ChatGPT, and T3 Code are already"
        echo "     allowed and Persistent. Do the same for any other terminal you use."
    fi
    echo "  2. Claude in Chrome extension: install it and sign in (for claude --chrome)."
    echo "  3. ChatGPT app: Plugins → Computer Use, and Settings → Computer Use → Chrome."
    echo "  4. Claude Code: /mcp → computer-use → Enable (per project), and optionally /chrome → Enabled by default."
    echo "  5. Training opt-outs, which are account settings: turn off model improvement in"
    echo "     claude.ai → Settings → Privacy, Improve the model for everyone in ChatGPT → Settings →"
    echo "     Data controls, and Include environments in the Codex settings on chatgpt.com/codex."
    echo "  See ai_tools/README.md for details."

    if "$extension_installed"; then
        echo "  Claude in Chrome extension already installed."
    fi

    # Only offer to open what still needs doing
    [ -n "$pending_notifications" ] && targets="the notification settings"
    "$open_extension" && targets="${targets:+$targets and }the Chrome extension page"
    if [ -z "$targets" ] || ! confirm "Open $targets now?"; then
        return 0
    fi

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

main() {
    open_manual_steps
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
