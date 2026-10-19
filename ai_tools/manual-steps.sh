#!/bin/bash
set -euo pipefail

# Print the AI tool steps scripts can't do on this OS.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../scripts/lib/markdown.sh
source "$DOTFILES_DIR/scripts/lib/markdown.sh"

CLAUDE_CHROME_EXTENSION_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
NOTIFICATION_SETTINGS="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"

# Print "<bundle id> <flags>" per app. Only keys of an app's own dict count, not nested ones.
notification_flags() {
    local xml
    xml="$(plutil -extract apps xml1 -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || return 1
    printf '%s\n' "$xml" | awk '
        /<dict>/ { if (++depth == 1) { id = ""; flags = "" } next }
        /<\/dict>/ { if (depth-- == 1 && id != "") print id, flags; next }
        depth != 1 { next }
        /<key>bundle-id<\/key>/ { want = "string"; next }
        /<key>flags<\/key>/ { want = "integer"; next }
        want != "" {
            if (match($0, "<" want ">[^<]*</" want ">")) {
                value = substr($0, RSTART + length(want) + 2, RLENGTH - 2 * length(want) - 5)
                if (want == "string") id = value; else flags = value
            }
            want = ""
        }'
}

# Print each given app not set to Allow + Persistent. Fails without Full Disk Access.
# Bits per https://github.com/drewdiver/ncprefs.py: 1<<25 allow, 1<<3 banners, 1<<4 alerts.
notifications_pending() {
    local apps id flags wanted=" $* " persistent=" "
    apps="$(notification_flags)" || return 1
    while read -r id flags; do
        [[ "$wanted" == *" $id "* ]] && [[ "$flags" =~ ^[0-9]+$ ]] || continue
        if (( (flags >> 25 & 1) && (flags >> 4 & 1) && !(flags >> 3 & 1) )); then
            persistent+="$id "
        fi
    done <<< "$apps"
    for id; do
        [[ "$persistent" == *" $id "* ]] || echo "$id"
    done
}

open_manual_steps() {
    local bundle_id pending_notifications="" readable=true extension_installed=false open_extension=false targets=""
    # Unreadable settings would count every app as pending, so don't offer to open them.
    if ! pending_notifications="$(notifications_pending com.anthropic.claudefordesktop \
        com.openai.codex com.t3tools.t3code)"; then
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
        echo "  In System Settings → Notifications, set Claude, ChatGPT, and T3 Code to Allow notifications + Persistent."
    elif [ -z "$pending_notifications" ]; then
        echo "  Notifications for Claude, ChatGPT, and T3 Code are already allowed and Persistent."
    fi
    if "$extension_installed"; then
        echo "  Claude in Chrome extension already installed."
    fi

    # DOTFILES_ASSUME_YES means a test machine, where nobody is there to set anything.
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

status() { return 0; }

apply() {
    if is_macos; then
        open_manual_steps
    else
        print_section Ubuntu
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
