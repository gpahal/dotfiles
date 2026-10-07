#!/bin/bash
set -euo pipefail

# Install the Claude desktop app and set its preferences. Claude must be quit first; when run
# interactively the script offers to quit it, otherwise it skips the settings.

# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

configure_claude_desktop() {
    echo "Configuring Claude desktop app..."
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
    local settings='
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
    if json_applied "$CLAUDE_DESKTOP_CONFIG" "$settings"; then
        echo "  Notifications, keep-awake, archiving, menu bar, quick entry, and Cowork settings are"
        echo "  already set"
        return 0
    fi
    ensure_app_quit "Claude" || return 0
    json_merge "$CLAUDE_DESKTOP_CONFIG" "$settings"
    echo "  Set notifications, keep-awake, archiving, no menu bar icon, Option+Space quick entry,"
    echo "  and Cowork browser, web search, and scheduled tasks"
}

main() {
    echo "Setting up the Claude desktop app..."
    install_cask claude /Applications/Claude.app
    configure_claude_desktop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
