#!/bin/bash
set -euo pipefail

# Install the Claude desktop app, open it at login, and set its preferences. Claude must be quit
# first; when run interactively the script offers to quit it, otherwise it skips the settings.
#
# A temp HOME doesn't isolate this step, which installs the claude cask into /Applications. Test it
# in a macOS VM or on a spare Mac.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
# A LaunchAgent that opens Claude at login, so its Option+Space quick entry works from the start.
# Claude's own "open at login" setting registers it through SMAppService, which no command can turn
# on for another app.
CLAUDE_DESKTOP_LOGIN_LABEL="dotfiles.claude-desktop"
CLAUDE_DESKTOP_LOGIN_AGENT="$HOME/Library/LaunchAgents/$CLAUDE_DESKTOP_LOGIN_LABEL.plist"

# Pass each file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it. The LaunchAgent isn't loaded now, since it would open Claude, which
# must be quit for the settings below. launchd loads it from ~/Library/LaunchAgents at the next
# login.
claude_desktop_files() {
    "$1" "$DOTFILES_DIR/ai_tools/claude-desktop/$CLAUDE_DESKTOP_LOGIN_LABEL.plist" "$CLAUDE_DESKTOP_LOGIN_AGENT"
}

# Settings → Claude Code:
#   Draw attention on notifications → On
#   Archive inactive sessions → 30 days
#   Keep computer awake while Claude works → On
#   Keep awake on battery power → On
# Settings → General:
#   Show in menu bar → Off (no menu bar icon, and no running in the background once the
#   window is closed)
# Also: Option+Space opens quick entry; scheduled tasks on in Code and Cowork; Cowork uses
# browser tools in Chrome and web search.
CLAUDE_DESKTOP_SETTINGS='
    .preferences.dockBounceEnabled = true
    | .preferences.ccAutoArchiveInactiveDays = 30
    | .preferences.ccKeepAwakeWhileWorking = true
    | .preferences.ccKeepAwakeOnBattery = true
    | .preferences.ccdScheduledTasksEnabled = true
    | .preferences.menuBarEnabled = false
    | .preferences.quickEntryShortcut |= ((if type == "object" then . else {} end) | .accelerator = "Alt+Space")
    | .preferences.coworkBrowserToolsEnabled = true
    | .preferences.coworkPreferredBrowser = "chrome"
    | .preferences.coworkWebSearchEnabled = true
    | .preferences.coworkScheduledTasksEnabled = true
'

configure_claude_desktop() {
    echo "Configuring Claude desktop app..."
    if json_applied "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_SETTINGS"; then
        echo "  Notifications, keep-awake, archiving, menu bar, quick entry, and Cowork settings are"
        echo "  already set"
        return 0
    fi
    ensure_app_quit "Claude" || return 0
    json_merge "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_SETTINGS" || return 1
    echo "  Set notifications, keep-awake, archiving, no menu bar icon, Option+Space quick entry,"
    echo "  and Cowork browser, web search, and scheduled tasks"
}

status() {
    if ! is_macos; then
        status_item skipped "Claude desktop app: macOS only"
        return 0
    fi
    if ! status_require_cmd jq "Claude desktop app"; then
        status_result
        return
    fi
    status_cask claude /Applications/Claude.app
    claude_desktop_files status_file
    status_check "Claude desktop app settings" json_applied "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_SETTINGS"
    status_result
}

apply() {
    echo "Setting up the Claude desktop app..."
    if ! is_macos; then
        echo "  The claude cask is macOS-only, and this machine is used over SSH; skipping."
        return 0
    fi
    require_cmd jq || return 1
    require_cmd brew || return 1
    local result=0
    install_cask claude /Applications/Claude.app || result=1
    claude_desktop_files copy_file || result=1
    configure_claude_desktop || result=1
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
