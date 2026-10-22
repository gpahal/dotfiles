#!/bin/bash
set -euo pipefail

# Set macOS defaults, the firewall, and App Store updates, and free Cmd+Space for Vicinae.
# Also sets the hostname when needed. Changes the real preferences, firewall, and hostname whatever
# HOME is: test it in a macOS VM or spare Mac.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/pam.sh
source "$DOTFILES_DIR/macos/lib/pam.sh"

STEP_OS=macos

APP_FIREWALL_DIR=/usr/libexec/ApplicationFirewall
APP_STORE_PREFS=/Library/Preferences/com.apple.commerce
SOFTWARE_UPDATE_PREFS=/Library/Preferences/com.apple.SoftwareUpdate

# activateSettings applies changed shortcuts without a logout
SYSTEM_ADMIN_DIR=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources

# Space bar is key code 49
hotkey_off_plist() {
    echo "<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>$1</integer></array><key>type</key><string>standard</string></dict></dict>"
}

# <hotkey id> <modifiers> <description> <app taking it>; Cmd is 1048576
symbolic_hotkeys() {
    "$@" 64 1048576 "Spotlight's Cmd+Space shortcut" "Vicinae"
}

# " domain:key" per change; " domain key," per failure
CHANGED_KEYS=""
FAILED_KEYS=""
SANDBOXED_KEYS=""
RUNNING_KEYS=""

# Apps that overwrite their domain on quit, losing a write made while they run
overwriting_app() {
    case "$1" in
        com.apple.ActivityMonitor) echo "Activity Monitor" ;;
    esac
}

# Returns 2 when the key is unset or in an unreadable sandboxed app's container
default_matches() {
    local domain="$1" key="$2" type="$3" value="$4" want="$4" current
    case "$type" in
        -bool) [ "$value" == "true" ] && want=1 || want=0 ;;
    esac
    current="$(defaults read "$domain" "$key" 2>/dev/null)" || return 2
    [ "$current" == "$want" ]
}

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
        # ~/Library/Containers needs Full Disk Access
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

# Unset or without an enabled key means on. Entries start at a four-space indent.
hotkey_off() {
    defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys 2>/dev/null |
        awk -v id="$1" '/^    [0-9]+ = / { on_id = $1 == id } on_id && /^ +enabled = / { off = $3 == "0;"; on_id = 0 } END { exit !off }'
}

disable_hotkey() {
    hotkey_off "$1" && return 0
    if ! defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$1" "$(hotkey_off_plist "$2")" 2>/dev/null; then
        echo "  Couldn't turn off $3."
        FAILED_KEYS+=" com.apple.symbolichotkeys AppleSymbolicHotKeys $1,"
        return 0
    fi
    echo "  Turned off $3"
    CHANGED_KEYS+=" com.apple.symbolichotkeys:$1"
}

status_hotkey() {
    local item
    item="$(printf '%s' "${3:0:1}" | tr '[:lower:]' '[:upper:]')${3:1}"
    status_check "$item off, so $4 can take it" hotkey_off "$1"
}

activate_settings_cmd() {
    PATH="$PATH:$SYSTEM_ADMIN_DIR" command -v activateSettings
}

status_default() {
    local result=0
    default_matches "$@" || result=$?
    if [ "$result" -eq 0 ]; then
        status_item ok "$1 $2 = $4"
    elif [ "$result" -eq 2 ] && [ -d "$HOME/Library/Containers/$1" ]; then
        status_item unverified "$1 $2 = $4: can't read it; give your terminal Full Disk Access to check it"
    else
        status_item missing "$1 $2 = $4"
    fi
}

each_default() {
    local apply="$1"

    "$apply" com.apple.finder AppleShowAllFiles -bool true
    "$apply" NSGlobalDomain AppleShowAllExtensions -bool true
    "$apply" com.apple.finder ShowPathbar -bool true
    "$apply" com.apple.finder ShowStatusBar -bool true
    # List view
    "$apply" com.apple.finder FXPreferredViewStyle -string Nlsv
    "$apply" com.apple.finder _FXSortFoldersFirst -bool true
    "$apply" com.apple.finder FXEnableExtensionChangeWarning -bool false
    # Search the current folder
    "$apply" com.apple.finder FXDefaultSearchScope -string SCcf
    "$apply" com.apple.finder _FXShowPosixPathInTitle -bool true
    "$apply" com.apple.desktopservices DSDontWriteNetworkStores -bool true
    "$apply" com.apple.desktopservices DSDontWriteUSBStores -bool true

    "$apply" NSGlobalDomain KeyRepeat -int 2
    "$apply" NSGlobalDomain InitialKeyRepeat -int 15
    "$apply" NSGlobalDomain ApplePressAndHoldEnabled -bool false

    "$apply" com.apple.dock autohide -bool true
    "$apply" com.apple.dock autohide-delay -float 0
    "$apply" com.apple.dock autohide-time-modifier -float 0.4
    "$apply" com.apple.dock minimize-to-application -bool true
    "$apply" com.apple.dock show-recents -bool false
    "$apply" com.apple.dock mru-spaces -bool false

    "$apply" com.apple.screencapture location -string "$HOME/Screenshots"
    "$apply" com.apple.screencapture type -string png
    "$apply" com.apple.screencapture disable-shadow -bool true

    "$apply" NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
    "$apply" NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
    "$apply" NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
    "$apply" NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
    "$apply" NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

    "$apply" NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
    "$apply" NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
    "$apply" NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
    "$apply" NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
    "$apply" NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

    "$apply" com.apple.TextEdit RichText -int 0

    # All Processes (View menu tag, from ActivityMonitor.nib)
    "$apply" com.apple.ActivityMonitor ShowCategory -int 100
}

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

firewall_cmd() {
    PATH="$PATH:$APP_FIREWALL_DIR" command -v socketfilterfw
}

# State 2 also blocks all incoming connections
firewall_on() {
    local cmd
    cmd="$(firewall_cmd)" || return 1
    case "$(run_bounded 10 "$cmd" --getglobalstate 2>/dev/null)" in
        *"State = 1"* | *"State = 2"*) return 0 ;;
    esac
    return 1
}

enable_firewall() {
    local cmd
    if ! cmd="$(firewall_cmd)" || ! sudo "$cmd" --setglobalstate on > /dev/null; then
        echo "  Couldn't turn on the application firewall." >&2
        return 1
    fi
    echo "  Turned on the application firewall"
}

stealth_mode_on() {
    local cmd
    cmd="$(firewall_cmd)" || return 1
    [[ "$(run_bounded 10 "$cmd" --getstealthmode 2>/dev/null)" == *"stealth mode is on"* ]]
}

enable_stealth_mode() {
    local cmd
    if ! cmd="$(firewall_cmd)" || ! sudo "$cmd" --setstealthmode on > /dev/null; then
        echo "  Couldn't turn on the firewall's stealth mode." >&2
        return 1
    fi
    echo "  Turned on the firewall's stealth mode"
}

app_store_auto_updates() {
    [ "$(defaults read "$APP_STORE_PREFS" AutoUpdate 2>/dev/null)" == 1 ] &&
        [ "$(defaults read "$SOFTWARE_UPDATE_PREFS" AutomaticallyInstallAppUpdates 2>/dev/null)" == 1 ]
}

enable_app_store_auto_updates() {
    if ! sudo defaults write "$APP_STORE_PREFS" AutoUpdate -bool true ||
        ! sudo defaults write "$SOFTWARE_UPDATE_PREFS" AutomaticallyInstallAppUpdates -bool true; then
        echo "  Couldn't turn on automatic App Store updates." >&2
        return 1
    fi
    echo "  Turned on automatic App Store updates"
}

# Without a HostName, macOS may use one with colons, which breaks OSC 7's URL. LocalHostName is
# always valid.
hostname_valid() {
    local name
    name="$(scutil --get HostName 2>/dev/null)" || return 1
    [[ "$name" =~ ^[A-Za-z0-9.-]+$ ]]
}

set_hostname() {
    local name
    if ! name="$(scutil --get LocalHostName)"; then
        echo "  Couldn't read the local hostname, so the hostname is left unset." >&2
        return 1
    fi
    if ! sudo scutil --set HostName "$name"; then
        echo "  Couldn't set the hostname." >&2
        return 1
    fi
    echo "  Set the hostname to $name. Shells started from now on use it."
}

screenshots_dir() {
    [ -d "$HOME/Screenshots" ]
}

make_screenshots_dir() {
    mkdir -p "$HOME/Screenshots"
}

macos_items() {
    local name
    name="$(scutil --get LocalHostName 2>/dev/null)" || name="the name in System Settings → General → Sharing"
    items_reset
    item "$HOME/Screenshots directory" "Create $HOME/Screenshots" screenshots_dir make_screenshots_dir
    item --sudo "Hostname set, so Ghostty's shell can report its folder" \
        "Set the hostname to $name, so Ghostty's shell can report its folder" hostname_valid set_hostname
    item --sudo "Application firewall on" "Turn on the application firewall" firewall_on enable_firewall
    item --sudo "Firewall stealth mode on, so the Mac ignores pings and port probes" \
        "Turn on the firewall's stealth mode" stealth_mode_on enable_stealth_mode
    item --sudo "App Store apps update automatically" "Turn on automatic App Store updates" \
        app_store_auto_updates enable_app_store_auto_updates
}

status() {
    macos_items
    each_default status_default
    items_status screenshots_dir
    symbolic_hotkeys status_hotkey
    items_status hostname_valid
    # Optional (just touch-id)
    status_touch_id skipped
    status_filevault
    items_status firewall_on stealth_mode_on app_store_auto_updates
    status_disk_space "$HOME"
    status_result
}

apply() {
    echo "Setting macOS defaults..."
    local status=0 pending=()
    macos_items
    items_pending
    if [ ${#pending[@]} -eq 0 ] || confirm_sudo_changes "${pending[@]}"; then
        items_apply || status=1
    else
        items_apply --no-sudo || status=1
    fi
    each_default set_default
    symbolic_hotkeys disable_hotkey

    if [ -z "$CHANGED_KEYS$FAILED_KEYS$SANDBOXED_KEYS$RUNNING_KEYS" ]; then
        echo "  macOS defaults are already set."
        return "$status"
    fi
    # Finder also reads the desktopservices keys and AppleShowAllExtensions
    [[ "$CHANGED_KEYS" == *com.apple.finder:* || "$CHANGED_KEYS" == *com.apple.desktopservices:* ||
        "$CHANGED_KEYS" == *NSGlobalDomain:AppleShowAllExtensions* ]] &&
        killall Finder 2>/dev/null || true
    [[ "$CHANGED_KEYS" == *com.apple.dock:* ]] && killall Dock 2>/dev/null || true
    [[ "$CHANGED_KEYS" == *com.apple.screencapture:* ]] && killall SystemUIServer 2>/dev/null || true
    # NSGlobalDomain changes, such as key repeat, need a new login session
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
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
