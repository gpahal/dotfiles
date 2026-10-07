#!/bin/bash
set -euo pipefail

# Set macOS defaults for Finder, Dock, keyboard, dialogs, and screenshots. Only writes values that
# differ, and only restarts Finder or Dock when one of theirs changed.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CHANGED_DOMAINS=""

# set_default <domain> <key> <-bool|-int|-float|-string> <value>
set_default() {
    local domain="$1" key="$2" type="$3" value="$4" want="$4" current
    case "$type" in
        -bool) [ "$value" == "true" ] && want=1 || want=0 ;;
    esac
    current="$(defaults read "$domain" "$key" 2>/dev/null || true)"
    [ "$current" == "$want" ] && return 0
    # Sandboxed apps (e.g. TextEdit) keep their defaults in ~/Library/Containers, which macOS
    # only lets a terminal with Full Disk Access write
    if ! defaults write "$domain" "$key" "$type" "$value" 2>/dev/null; then
        echo "  Couldn't set $domain $key: give your terminal Full Disk Access in System Settings →"
        echo "  Privacy & Security, or change it in the app"
        return 0
    fi
    echo "  Set $domain $key to $value"
    CHANGED_DOMAINS+=" $domain"
}

main() {
    echo "Setting macOS defaults..."

    # Finder: show hidden files and all file extensions
    set_default com.apple.finder AppleShowAllFiles -bool true
    set_default NSGlobalDomain AppleShowAllExtensions -bool true
    # Finder: show path bar and status bar
    set_default com.apple.finder ShowPathbar -bool true
    set_default com.apple.finder ShowStatusBar -bool true
    # Finder: default to list view, with folders on top when sorting
    set_default com.apple.finder FXPreferredViewStyle -string Nlsv
    set_default com.apple.finder _FXSortFoldersFirst -bool true
    # Finder: no warning when changing a file extension
    set_default com.apple.finder FXEnableExtensionChangeWarning -bool false
    # Finder: search the current folder by default
    set_default com.apple.finder FXDefaultSearchScope -string SCcf
    # Finder: show the full POSIX path in the window title
    set_default com.apple.finder _FXShowPosixPathInTitle -bool true
    # No .DS_Store files on network and USB volumes
    set_default com.apple.desktopservices DSDontWriteNetworkStores -bool true
    set_default com.apple.desktopservices DSDontWriteUSBStores -bool true

    # Fast key repeat (essential for vim), and repeat instead of press-and-hold accents
    set_default NSGlobalDomain KeyRepeat -int 2
    set_default NSGlobalDomain InitialKeyRepeat -int 15
    set_default NSGlobalDomain ApplePressAndHoldEnabled -bool false

    # Dock: auto-hide with no delay, and minimize to the application icon
    set_default com.apple.dock autohide -bool true
    set_default com.apple.dock autohide-delay -float 0
    set_default com.apple.dock autohide-time-modifier -float 0.4
    set_default com.apple.dock minimize-to-application -bool true
    # Dock: no recent apps section
    set_default com.apple.dock show-recents -bool false
    # Spaces: keep their order instead of rearranging by most recent use
    set_default com.apple.dock mru-spaces -bool false

    # Screenshots: save to ~/Screenshots as PNG
    mkdir -p "$HOME/Screenshots"
    set_default com.apple.screencapture location -string "$HOME/Screenshots"
    set_default com.apple.screencapture type -string png
    # Screenshots: no window shadow
    set_default com.apple.screencapture disable-shadow -bool true

    # No smart quotes and dashes (they break code in terminals)
    set_default NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
    set_default NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
    # No autocorrect, auto-capitalization, or double-space period
    set_default NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
    set_default NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
    set_default NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

    # Save and print dialogs: expanded by default
    set_default NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
    set_default NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
    set_default NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
    set_default NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
    # Save new documents to disk, not iCloud
    set_default NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

    # TextEdit: plain text by default
    set_default com.apple.TextEdit RichText -int 0

    # Activity Monitor: show all processes
    set_default com.apple.ActivityMonitor ShowCategory -int 0

    if [ -z "$CHANGED_DOMAINS" ]; then
        echo "  macOS defaults are already set."
        return 0
    fi
    # Finder is what writes .DS_Store files, so it also picks up the desktopservices keys
    [[ "$CHANGED_DOMAINS" == *com.apple.finder* || "$CHANGED_DOMAINS" == *com.apple.desktopservices* ]] &&
        killall Finder 2>/dev/null || true
    [[ "$CHANGED_DOMAINS" == *com.apple.dock* ]] && killall Dock 2>/dev/null || true
    echo "  Some settings apply after you log out and back in."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
