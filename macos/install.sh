#!/bin/bash
set -euo pipefail

# Set macOS defaults for Finder, Dock, keyboard, dialogs, and screenshots, and turn off Spotlight's
# Cmd+Space shortcut, so Raycast can take it. Only writes values that differ, and only restarts
# Finder, Dock, or SystemUIServer when one of theirs changed.
#
# A temp HOME doesn't isolate this step. defaults writes the real preferences whatever HOME is, and
# the step restarts the real Finder, Dock, and SystemUIServer. Test it in a macOS VM or on a spare
# Mac.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# The Touch ID status check, without the Touch ID script's main and status
# shellcheck source=pam.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pam.sh"

# socketfilterfw reads the application firewall's settings, and isn't on PATH
APP_FIREWALL_DIR=/usr/libexec/ApplicationFirewall

# activateSettings applies changed keyboard shortcuts without a logout, and isn't on PATH
SYSTEM_ADMIN_DIR=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources

# Spotlight's "Show Spotlight search" shortcut, symbolic hotkey 64, as Cmd+Space (space is key code
# 49, Cmd is 1048576) and turned off. Raycast's own setting binds Cmd+Space once it's free.
SPOTLIGHT_HOTKEY_OFF="<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>"

# Each changed setting as " domain:key", and each one whose write failed as " domain key": in
# SANDBOXED_KEYS for a sandboxed app, which needs Full Disk Access (a manual step), and in
# FAILED_KEYS for anything else, which fails the step
CHANGED_KEYS=""
FAILED_KEYS=""
SANDBOXED_KEYS=""
# Each setting left unchanged because its app was running, as " domain key"
RUNNING_KEYS=""

# Print the app that owns a domain and overwrites it with its own value when it quits, so a write
# while it runs is lost
overwriting_app() {
    case "$1" in
        com.apple.ActivityMonitor) echo "Activity Monitor" ;;
    esac
}

# default_matches <domain> <key> <-bool|-int|-float|-string> <value>
# Succeeds when a setting already has the value. Returns 2 when `defaults read` can't read it: it's
# unset, or it belongs to a sandboxed app whose settings the terminal can't read.
default_matches() {
    local domain="$1" key="$2" type="$3" value="$4" want="$4" current
    case "$type" in
        -bool) [ "$value" == "true" ] && want=1 || want=0 ;;
    esac
    current="$(defaults read "$domain" "$key" 2>/dev/null)" || return 2
    [ "$current" == "$want" ]
}

# set_default <domain> <key> <-bool|-int|-float|-string> <value>
set_default() {
    local domain="$1" key="$2" type="$3" value="$4"
    local app
    default_matches "$@" && return 0
    app="$(overwriting_app "$domain")"
    if [ -n "$app" ] && ! ensure_app_quit "$app"; then
        RUNNING_KEYS+=" $domain $key,"
        return 0
    fi
    if ! defaults write "$domain" "$key" "$type" "$value" 2>/dev/null; then
        # Sandboxed apps (e.g. TextEdit) keep their defaults in ~/Library/Containers, which macOS
        # only lets a terminal with Full Disk Access write
        if [ -d "$HOME/Library/Containers/$domain" ]; then
            SANDBOXED_KEYS+=" $domain $key,"
        else
            echo "  Couldn't set $domain $key."
            FAILED_KEYS+=" $domain $key,"
        fi
        return 0
    fi
    echo "  Set $domain $key to $value"
    CHANGED_KEYS+=" $domain:$key"
}

# Succeeds when symbolic hotkey 64 is turned off. defaults prints AppleSymbolicHotKeys in the
# old-style plist format, where each hotkey's entry starts at a four-space indent.
spotlight_shortcut_off() {
    defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys 2>/dev/null |
        awk '/^    64 = / { in64 = 1 } in64 && /^ +enabled = / { off = $3 == "0;"; in64 = 0 } END { exit !off }'
}

disable_spotlight_shortcut() {
    spotlight_shortcut_off && return 0
    if ! defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 "$SPOTLIGHT_HOTKEY_OFF" 2>/dev/null; then
        echo "  Couldn't turn off Spotlight's Cmd+Space shortcut."
        FAILED_KEYS+=" com.apple.symbolichotkeys AppleSymbolicHotKeys,"
        return 0
    fi
    echo "  Turned off Spotlight's Cmd+Space shortcut"
    CHANGED_KEYS+=" com.apple.symbolichotkeys:64"
}

# Print activateSettings's path
activate_settings_cmd() {
    PATH="$PATH:$SYSTEM_ADMIN_DIR" command -v activateSettings
}

# Print an item for a setting, reading it with `defaults read` and writing nothing
status_default() {
    local result=0
    default_matches "$@" || result=$?
    if [ "$result" -eq 0 ]; then
        status_item ok "$1 $2 = $4"
    elif [ "$result" -eq 2 ] && [ -d "$HOME/Library/Containers/$1" ]; then
        # Sandboxed apps (e.g. TextEdit) keep their defaults in ~/Library/Containers
        status_item unverified "$1 $2 = $4: can't read it; give your terminal Full Disk Access to check it"
    else
        status_item missing "$1 $2 = $4"
    fi
}

# Pass each setting to a function: set_default to apply it, or status_default to report it
each_default() {
    local apply="$1"

    # Finder: show hidden files and all file extensions
    "$apply" com.apple.finder AppleShowAllFiles -bool true
    "$apply" NSGlobalDomain AppleShowAllExtensions -bool true
    # Finder: show path bar and status bar
    "$apply" com.apple.finder ShowPathbar -bool true
    "$apply" com.apple.finder ShowStatusBar -bool true
    # Finder: default to list view, with folders on top when sorting
    "$apply" com.apple.finder FXPreferredViewStyle -string Nlsv
    "$apply" com.apple.finder _FXSortFoldersFirst -bool true
    # Finder: no warning when changing a file extension
    "$apply" com.apple.finder FXEnableExtensionChangeWarning -bool false
    # Finder: search the current folder by default
    "$apply" com.apple.finder FXDefaultSearchScope -string SCcf
    # Finder: show the full POSIX path in the window title
    "$apply" com.apple.finder _FXShowPosixPathInTitle -bool true
    # No .DS_Store files on network and USB volumes
    "$apply" com.apple.desktopservices DSDontWriteNetworkStores -bool true
    "$apply" com.apple.desktopservices DSDontWriteUSBStores -bool true

    # Fast key repeat (essential for vim), and repeat instead of press-and-hold accents
    "$apply" NSGlobalDomain KeyRepeat -int 2
    "$apply" NSGlobalDomain InitialKeyRepeat -int 15
    "$apply" NSGlobalDomain ApplePressAndHoldEnabled -bool false

    # Dock: auto-hide with no delay, and minimize to the application icon
    "$apply" com.apple.dock autohide -bool true
    "$apply" com.apple.dock autohide-delay -float 0
    "$apply" com.apple.dock autohide-time-modifier -float 0.4
    "$apply" com.apple.dock minimize-to-application -bool true
    # Dock: no recent apps section
    "$apply" com.apple.dock show-recents -bool false
    # Spaces: keep their order instead of rearranging by most recent use
    "$apply" com.apple.dock mru-spaces -bool false

    # Screenshots: save to ~/Screenshots (which main creates) as PNG
    "$apply" com.apple.screencapture location -string "$HOME/Screenshots"
    "$apply" com.apple.screencapture type -string png
    # Screenshots: no window shadow
    "$apply" com.apple.screencapture disable-shadow -bool true

    # No smart quotes and dashes (they break code in terminals)
    "$apply" NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
    "$apply" NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
    # No autocorrect, auto-capitalization, or double-space period
    "$apply" NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
    "$apply" NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
    "$apply" NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

    # Save and print dialogs: expanded by default
    "$apply" NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
    "$apply" NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
    "$apply" NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
    "$apply" NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
    # Save new documents to disk, not iCloud
    "$apply" NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

    # TextEdit: plain text by default
    "$apply" com.apple.TextEdit RichText -int 0

    # Activity Monitor: show all processes. ShowCategory holds the tag of the chosen View menu item:
    # 100 is All Processes, and 101 to 111 are the other views (from the menu in its
    # ActivityMonitor.nib, on macOS 27).
    "$apply" com.apple.ActivityMonitor ShowCategory -int 100
}

# Information, not a setting the step makes: whether FileVault encrypts the disk
status_filevault() {
    local out
    if ! command -v fdesetup &>/dev/null; then
        status_item info "FileVault: couldn't tell, since fdesetup isn't on PATH"
        return 0
    fi
    out="$(run_bounded 10 fdesetup status 2>&1)" || true
    case "$out" in
        *"FileVault is On"*"Encryption in progress"*) status_item info "FileVault: on, encryption in progress" ;;
        *"FileVault is On"*"Decryption in progress"*) status_item info "FileVault: on, decryption in progress" ;;
        *"FileVault is On"*) status_item info "FileVault: on" ;;
        *"FileVault is Off"*) status_item info "FileVault: off (System Settings → Privacy & Security turns it on)" ;;
        *root* | *[Pp]ermission* | *"not authorized"*) status_item unverified "FileVault: reading it needs more privilege; check it with sudo fdesetup status" ;;
        *) status_item info "FileVault: couldn't tell from fdesetup status (${out%%$'\n'*})" ;;
    esac
}

# Print socketfilterfw's path
firewall_cmd() {
    PATH="$PATH:$APP_FIREWALL_DIR" command -v socketfilterfw
}

# Information, not a setting the step makes: whether the application firewall is on
status_app_firewall() {
    local cmd out
    if ! cmd="$(firewall_cmd)"; then
        status_item info "Application firewall: couldn't tell, since $APP_FIREWALL_DIR/socketfilterfw is missing"
        return 0
    fi
    out="$(run_bounded 10 "$cmd" --getglobalstate 2>&1)" || true
    case "$out" in
        *"State = 2"* | *"blocking all"*) status_item info "Application firewall: on, blocking all incoming connections" ;;
        *"State = 1"* | *"is enabled"*) status_item info "Application firewall: on" ;;
        *"State = 0"* | *"is disabled"*) status_item info "Application firewall: off (System Settings → Network → Firewall turns it on)" ;;
        *root* | *[Pp]ermission*) status_item unverified "Application firewall: reading it needs more privilege; check it with sudo $cmd --getglobalstate" ;;
        *) status_item info "Application firewall: couldn't tell from socketfilterfw --getglobalstate (${out%%$'\n'*})" ;;
    esac
}

status() {
    if ! is_macos; then
        status_item skipped "macOS defaults: macOS only"
        return 0
    fi
    each_default status_default
    # The screenshot location key points here, and main creates it
    status_check "$HOME/Screenshots directory" test -d "$HOME/Screenshots"
    status_check "Spotlight's Cmd+Space shortcut off, so Raycast can take it" spotlight_shortcut_off
    # Touch ID for sudo is optional (just touch-id), so off is skipped
    status_touch_id skipped
    status_filevault
    status_app_firewall
    status_disk_space "$HOME"
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Setting macOS defaults..."
    if ! is_macos; then
        echo "  Not macOS; skipping."
        return 0
    fi
    mkdir -p "$HOME/Screenshots"
    each_default set_default
    disable_spotlight_shortcut

    if [ -z "$CHANGED_KEYS$FAILED_KEYS$SANDBOXED_KEYS$RUNNING_KEYS" ]; then
        echo "  macOS defaults are already set."
        return 0
    fi
    # Finder is what writes .DS_Store files, so it also picks up the desktopservices keys. It
    # reads AppleShowAllExtensions from the global domain.
    [[ "$CHANGED_KEYS" == *com.apple.finder:* || "$CHANGED_KEYS" == *com.apple.desktopservices:* ||
        "$CHANGED_KEYS" == *NSGlobalDomain:AppleShowAllExtensions* ]] &&
        killall Finder 2>/dev/null || true
    [[ "$CHANGED_KEYS" == *com.apple.dock:* ]] && killall Dock 2>/dev/null || true
    # SystemUIServer takes the screenshots, and reads their settings when it starts
    [[ "$CHANGED_KEYS" == *com.apple.screencapture:* ]] && killall SystemUIServer 2>/dev/null || true
    # Apps read the global domain when they start, and key repeat needs a new login session
    local logout=false cmd
    [[ "$CHANGED_KEYS" != *NSGlobalDomain:* ]] || logout=true
    if [[ "$CHANGED_KEYS" == *com.apple.symbolichotkeys:* ]]; then
        if ! cmd="$(activate_settings_cmd)" || ! "$cmd" -u; then
            logout=true
        fi
    fi
    ! "$logout" || echo "  Some settings apply after you log out and back in."
    if [ -n "$SANDBOXED_KEYS" ]; then
        echo "  Couldn't set${SANDBOXED_KEYS%,}, which belong to sandboxed apps."
        echo "  Give your terminal Full Disk Access in System Settings → Privacy & Security and re-run"
        echo "  this step, or change them in the app: for TextEdit, Format → Plain Text in its settings."
    fi
    if [ -n "$FAILED_KEYS" ]; then
        echo "  Failed to set${FAILED_KEYS%,}." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
