#!/bin/bash
set -euo pipefail

# Install the Claude desktop app and set its preferences. Claude must be quit first; when run
# interactively the script offers to quit it, otherwise it skips the settings.
#
# A temp HOME doesn't isolate this step, which installs the claude cask into /Applications. Test it
# in a macOS VM or on a spare Mac.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

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
    | .preferences.quickEntryShortcut = {"accelerator": "Alt+Space"}
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
    status_check "Claude desktop app settings" json_applied "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_SETTINGS"
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Setting up the Claude desktop app..."
    if ! is_macos; then
        echo "  The claude cask is macOS-only, and this machine is used over SSH; skipping."
        return 0
    fi
    require_cmd jq || return 1
    require_cmd brew || return 1
    local result=0
    install_cask claude /Applications/Claude.app || result=1
    configure_claude_desktop || result=1
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
