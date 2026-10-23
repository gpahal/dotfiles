#!/bin/bash
set -euo pipefail

# Install the Claude desktop app, open it at login, and set its preferences.
# Installs into /Applications, or on Ubuntu with sudo from Anthropic's apt repo, whatever HOME is:
# test in a macOS VM or on a spare Mac, or in an Ubuntu VM.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"
# shellcheck source=../../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/app-json.sh
source "$DOTFILES_DIR/ai_tools/lib/app-json.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

CLAUDE_DESKTOP_MACOS_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
# Not XDG_CONFIG_HOME on Ubuntu: GNOME starts the app and its autostart without the shell's
CLAUDE_DESKTOP_UBUNTU_CONFIG="$HOME/.config/Claude/claude_desktop_config.json"
# Opens Claude at login. Claude's own setting uses SMAppService, which no command can turn on.
CLAUDE_DESKTOP_LOGIN_LABEL="dotfiles.claude-desktop"
CLAUDE_DESKTOP_LOGIN_AGENT="$HOME/Library/LaunchAgents/$CLAUDE_DESKTOP_LOGIN_LABEL.plist"
# On Ubuntu, the file Claude's own "open at login" setting writes, byte for byte, so Claude's own
# toggle shows it on
CLAUDE_DESKTOP_AUTOSTART="$HOME/.config/autostart/claude-desktop.desktop"

# Anthropic's apt source as the claude-desktop package writes it, marker lines included, so the
# package treats it as its own and keeps it unchanged
CLAUDE_APT_SOURCES=/etc/apt/sources.list.d/claude-desktop.list
CLAUDE_APT_SOURCES_CONTENT='### Managed by the claude-desktop package.
### Set CLAUDE_DESKTOP_ADD_REPO="true"|"false" in /etc/default/claude-desktop
### to force this entry on or off; remove this file too when opting out.
deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main'
CLAUDE_APT_KEYRING=/usr/share/keyrings/claude-desktop-archive-keyring.asc
CLAUDE_APT_KEY_URL=https://downloads.claude.ai/claude-desktop/key.asc
# "Anthropic Claude Code Release Signing", as https://code.claude.com/docs/en/desktop-linux gives it
CLAUDE_APT_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
CLAUDE_APT_RELEASE_URL=https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/Release

claude_desktop_config() {
    if is_macos; then
        echo "$CLAUDE_DESKTOP_MACOS_CONFIG"
    else
        echo "$CLAUDE_DESKTOP_UBUNTU_CONFIG"
    fi
}

# Not loaded now: it would open Claude, which must be quit for the settings merge.
claude_desktop_files() {
    if is_macos; then
        "$1" "$DOTFILES_DIR/ai_tools/claude-desktop/$CLAUDE_DESKTOP_LOGIN_LABEL.plist" "$CLAUDE_DESKTOP_LOGIN_AGENT"
    else
        "$1" "$DOTFILES_DIR/ai_tools/claude-desktop/claude-desktop.desktop" "$CLAUDE_DESKTOP_AUTOSTART"
    fi
}

# menuBarEnabled off also stops it running in the background once the window closes.
CLAUDE_DESKTOP_SETTINGS='
    .preferences.ccAutoArchiveInactiveDays = 30
    | .preferences.ccKeepAwakeWhileWorking = true
    | .preferences.ccKeepAwakeOnBattery = true
    | .preferences.ccdScheduledTasksEnabled = true
    | .preferences.menuBarEnabled = false
    | .preferences.coworkBrowserToolsEnabled = true
    | .preferences.coworkPreferredBrowser = "chrome"
    | .preferences.coworkWebSearchEnabled = true
    | .preferences.coworkScheduledTasksEnabled = true
'
# dockBounceEnabled is "Draw attention on notifications", for the Dock. GNOME takes Alt+Space for
# the window menu, and Ctrl+Alt+Super+Space opens Claude there.
CLAUDE_DESKTOP_MACOS_SETTINGS='
    .preferences.dockBounceEnabled = true
    | .preferences.quickEntryShortcut |= ((if type == "object" then . else {} end) | .accelerator = "Alt+Space")
'

claude_desktop_settings() {
    if is_macos; then
        echo "$CLAUDE_DESKTOP_MACOS_SETTINGS | $CLAUDE_DESKTOP_SETTINGS"
    else
        echo "$CLAUDE_DESKTOP_SETTINGS"
    fi
}

configure_claude_desktop() {
    echo "Configuring Claude desktop app..."
    if is_macos; then
        merge_app_json Claude \
            "Notifications, keep-awake, archiving, menu bar, quick entry, and Cowork settings are
already set" \
            "Set notifications, keep-awake, archiving, no menu bar icon, Option+Space quick entry,
and Cowork browser, web search, and scheduled tasks" \
            "$(claude_desktop_config)" "$(claude_desktop_settings)"
    else
        # Linux names the process after its executable
        merge_app_json claude-desktop \
            "Keep-awake, archiving, tray icon, and Cowork settings are already set" \
            "Set keep-awake, archiving, no tray icon, and Cowork browser, web search, and scheduled
tasks" \
            "$(claude_desktop_config)" "$(claude_desktop_settings)"
    fi
}

claude_apt_installed() {
    apt_installed claude-desktop && file_is "$CLAUDE_APT_SOURCES" "$CLAUDE_APT_SOURCES_CONTENT"
}

# Runs where set -e is off: each command checks its own failure
install_claude_apt() {
    apt_repo_published Claude "$CLAUDE_APT_RELEASE_URL" || return 1
    add_apt_repo Claude "$CLAUDE_APT_SOURCES" "$CLAUDE_APT_SOURCES_CONTENT" "$CLAUDE_APT_KEY_URL" \
        "$CLAUDE_APT_KEYRING" "$CLAUDE_APT_KEY_FPR" || return 1
    apt_get install -y claude-desktop
}

claude_desktop_ubuntu_items() {
    items_reset
    item --sudo "Claude desktop app from Anthropic's apt repo" \
        "Add Anthropic's apt repo ($CLAUDE_APT_SOURCES) and install claude-desktop" \
        claude_apt_installed install_claude_apt
}

status() {
    if is_ubuntu && ! has_gnome_desktop; then
        status_item skipped "Claude desktop app: no GNOME desktop"
        return 0
    fi
    if is_macos; then
        status_cask claude /Applications/Claude.app
    else
        claude_desktop_ubuntu_items
        items_status
    fi
    claude_desktop_files status_file
    if status_require_cmd jq "Claude desktop app settings"; then
        status_check "Claude desktop app settings" json_applied "$(claude_desktop_config)" "$(claude_desktop_settings)"
    fi
}

apply() {
    echo "Setting up the Claude desktop app..."
    if is_ubuntu && ! has_gnome_desktop; then
        echo "  No GNOME desktop, so no desktop app."
        return 0
    fi
    require_cmd jq || return 1
    local result=0
    if is_macos; then
        require_cmd brew || return 1
        install_cask claude /Applications/Claude.app || result=1
    else
        claude_desktop_ubuntu_items
        if items_ok; then
            echo "  claude-desktop is already installed from Anthropic's apt repo."
        else
            items_apply_confirmed || result=1
        fi
    fi
    claude_desktop_files copy_file || result=1
    configure_claude_desktop || result=1
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
