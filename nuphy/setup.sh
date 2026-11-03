#!/bin/bash
set -euo pipefail

# Load the NuPhy Air75 V3 backup in nuphy/ onto the keyboard, or save fresh exports from NuPhy IO.
# NuPhy IO reaches the keyboard only from Chrome, over WebHID, which needs you to pick the device,
# so this opens it, puts each file's path on the clipboard, and says what to click. Setup doesn't
# run it. Usage: bash nuphy/setup.sh [import|export]
# NuPhy IO checks each file against the hashes inside it, so keep the files byte for byte.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

NUPHY_IO_URL=https://drive.nuphy.io
NUPHY_DIR="$DOTFILES_DIR/nuphy"
NUPHY_VENDOR_ID=19f5
CHROME_APP="/Applications/Google Chrome.app"
USB_DEVICES_DIR=/sys/bus/usb/devices
# <file in nuphy/>|<NuPhy IO's name for its export, a glob that takes Chrome's " (1)">|<what it is>
BACKUPS=(
    "air75-v3-mac-mode.json|*Mode_Config_mac*.json|the Mac mode"
    "air75-v3-windows-mode.json|*Mode_Config_windows*.json|the Windows mode"
    "air75-v3-macro-screenshot.json|MACRO 1*.json|macro 1, Cmd+Ctrl+Shift+4 on the Mac mode's screenshot key"
)

usage() {
    echo "Usage: bash nuphy/setup.sh [import|export]"
    echo "  import (the default): load nuphy/'s modes and macro onto the keyboard through NuPhy IO"
    echo "  export: save the keyboard's modes and macro from NuPhy IO to nuphy/"
}

# The keyboard, or its 2.4G receiver, on USB. NuPhy IO can't reach it over Bluetooth.
keyboard_connected() {
    local file
    if is_macos; then
        ioreg -p IOUSB -l -w0 2>/dev/null | grep "\"idVendor\" = $((16#$NUPHY_VENDOR_ID))\$" >/dev/null
        return
    fi
    for file in "$USB_DEVICES_DIR"/*/idVendor; do
        [ "$(cat "$file" 2>/dev/null)" != "$NUPHY_VENDOR_ID" ] || return 0
    done
    return 1
}

# Fails, saying why, before anything opens
check_ready() {
    if ! is_interactive; then
        echo "Run this from a terminal: it waits for you at each step." >&2
        return 1
    fi
    if is_macos; then
        if [ ! -d "$CHROME_APP" ]; then
            echo "Google Chrome isn't installed. Run bash setup.sh homebrew first; NuPhy IO needs Chrome." >&2
            return 1
        fi
    else
        if ! command -v google-chrome &>/dev/null; then
            echo "Google Chrome isn't installed. Run bash setup.sh chrome first; NuPhy IO needs Chrome." >&2
            return 1
        fi
        if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
            echo "Run this at the desktop, where Chrome can open, not over SSH." >&2
            return 1
        fi
    fi
    if ! keyboard_connected; then
        echo "The Air75 V3 isn't on USB. Plug in its cable or its 2.4G receiver; NuPhy IO can't reach" >&2
        echo "it over Bluetooth." >&2
        return 1
    fi
}

open_nuphy_io() {
    echo "Opening NuPhy IO ($NUPHY_IO_URL) in Chrome..."
    if is_macos; then
        open -a "$CHROME_APP" "$NUPHY_IO_URL"
    else
        (google-chrome "$NUPHY_IO_URL" &>/dev/null &)
    fi
}

wait_for_you() {
    read -r -p "  Press Enter when that's done, or Ctrl-C to stop. " _ || true
}

# copy_path <file>: puts it on the clipboard for Chrome's file dialog, and says how to paste it
copy_path() {
    local copied=false
    if is_macos; then
        printf '%s' "$1" | pbcopy 2>/dev/null && copied=true
    elif command -v wl-copy &>/dev/null; then
        printf '%s' "$1" | wl-copy 2>/dev/null && copied=true
    fi
    if ! "$copied"; then
        echo "  In the file dialog, open $1."
    elif is_macos; then
        echo "  Its path is on the clipboard. In the file dialog, press Cmd+Shift+G, then Cmd+V and Return."
    else
        echo "  Its path is on the clipboard. In the file dialog, press Ctrl+L, then Ctrl+V and Enter."
    fi
}

import_backup() {
    local backup file what n=1 total=$((${#BACKUPS[@]} + 1))
    for backup in "${BACKUPS[@]}"; do
        file="${backup%%|*}"
        if [ ! -f "$NUPHY_DIR/$file" ]; then
            echo "$(shown_path "$NUPHY_DIR/$file") is missing. Restore it from git, or run bash nuphy/setup.sh export." >&2
            return 1
        fi
    done
    check_ready || return 1
    echo "This replaces the keyboard's Mac and Windows modes and its macro with the backup in $(shown_path "$NUPHY_DIR")."
    if ! confirm "Go ahead?"; then
        echo "Left the keyboard unchanged."
        return 0
    fi
    open_nuphy_io
    echo
    echo "$n/$total. In NuPhy IO, authorize the keyboard: pick Air75 V3, or Air75 V3 Dongle on the receiver."
    wait_for_you
    for backup in "${BACKUPS[@]}"; do
        n=$((n + 1))
        file="${backup%%|*}"
        what="${backup##*|}"
        echo
        case "$file" in
            *-mode.json)
                echo "$n/$total. Import ${what}: under Onboard Mode, pick ${what#the }, choose Import, keep every part"
                echo "  selected, and Select a file: $file."
                ;;
            *)
                echo "$n/$total. Import ${what}: in Macro Recording, choose Import Macros and pick $file."
                ;;
        esac
        copy_path "$NUPHY_DIR/$file"
        wait_for_you
    done
    echo
    echo "The keyboard keeps what NuPhy IO imported; there's nothing to save. If NuPhy IO asks you to"
    echo "set the switch or Fn key after an import, set them as they were."
}

downloads_dir() {
    local dir=""
    is_macos || dir="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    echo "${dir:-$HOME/Downloads}"
}

# newest_since <dir> <glob> <marker>: the newest file in dir matching the glob, case aside, that's
# newer than the marker
newest_since() {
    local file name newest=""
    shopt -s nocasematch
    for file in "$1"/*; do
        name="${file##*/}"
        # shellcheck disable=SC2254 # the glob is a pattern
        case "$name" in
            $2) ;;
            *) continue ;;
        esac
        [ -f "$file" ] && [ "$file" -nt "$3" ] || continue
        [ -z "$newest" ] || [ "$file" -nt "$newest" ] || continue
        newest="$file"
    done
    shopt -u nocasematch
    [ -n "$newest" ] && echo "$newest"
}

# A mode export is JSON with a keymap; a macro export is URL-encoded JSON
looks_like() {
    case "$1" in
        *-mode.json) jq -e 'has("c") and has("k")' "$2" &>/dev/null ;;
        *) [ "$(head -c 3 "$2")" == "%7B" ] ;;
    esac
}

export_backup() {
    local backup file glob what found marker downloads saved=0 result=0
    require_cmd jq || return 1
    check_ready || return 1
    downloads="$(downloads_dir)"
    marker="$(mktemp)" || return 1
    open_nuphy_io
    echo
    echo "In NuPhy IO, authorize the keyboard, then:"
    echo "  - Under Onboard Mode, Export the Mac mode and the Windows mode."
    echo "  - In Macro Recording, choose Export Macros."
    echo "Chrome saves them to $(shown_path "$downloads")."
    wait_for_you
    echo
    for backup in "${BACKUPS[@]}"; do
        IFS='|' read -r file glob what <<< "$backup"
        if ! found="$(newest_since "$downloads" "$glob" "$marker")"; then
            echo "  Found no new export of $what in $(shown_path "$downloads"), so $(shown_path "$NUPHY_DIR/$file") is unchanged."
            continue
        fi
        if ! looks_like "$file" "$found"; then
            echo "  $(shown_path "$found") isn't a NuPhy IO export of $what, so it was left there." >&2
            result=1
            continue
        fi
        if mv -f "$found" "$NUPHY_DIR/$file"; then
            echo "  Saved $what to $(shown_path "$NUPHY_DIR/$file")"
            saved=$((saved + 1))
        else
            echo "  Couldn't move $(shown_path "$found") to $(shown_path "$NUPHY_DIR/$file")." >&2
            result=1
        fi
    done
    rm -f "$marker"
    [ "$saved" -eq 0 ] || echo "Commit $(shown_path "$NUPHY_DIR") to keep them."
    return "$result"
}

main() {
    case "${1:-import}" in
        import) import_backup ;;
        export) export_backup ;;
        -h | --help) usage ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
