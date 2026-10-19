#!/bin/bash
set -euo pipefail

# Install the Claude desktop app, open it at login, and set its preferences.
# Installs into /Applications whatever HOME is; test in a macOS VM or on a spare Mac.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"
# shellcheck source=../lib/app-json.sh
source "$DOTFILES_DIR/ai_tools/lib/app-json.sh"

STEP_OS=macos
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
# Opens Claude at login. Claude's own setting uses SMAppService, which no command can turn on.
CLAUDE_DESKTOP_LOGIN_LABEL="dotfiles.claude-desktop"
CLAUDE_DESKTOP_LOGIN_AGENT="$HOME/Library/LaunchAgents/$CLAUDE_DESKTOP_LOGIN_LABEL.plist"

# Not loaded now: it would open Claude, which must be quit for the settings merge.
claude_desktop_files() {
    "$1" "$DOTFILES_DIR/ai_tools/claude-desktop/$CLAUDE_DESKTOP_LOGIN_LABEL.plist" "$CLAUDE_DESKTOP_LOGIN_AGENT"
}

# dockBounceEnabled is "Draw attention on notifications". menuBarEnabled off also stops it
# running in the background once the window closes.
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
    merge_app_json Claude \
        "Notifications, keep-awake, archiving, menu bar, quick entry, and Cowork settings are
already set" \
        "Set notifications, keep-awake, archiving, no menu bar icon, Option+Space quick entry,
and Cowork browser, web search, and scheduled tasks" \
        "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_SETTINGS"
}

status() {
    status_cask claude /Applications/Claude.app
    claude_desktop_files status_file
    if status_require_cmd jq "Claude desktop app settings"; then
        status_check "Claude desktop app settings" json_applied "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_SETTINGS"
    fi
    status_result
}

apply() {
    echo "Setting up the Claude desktop app..."
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
