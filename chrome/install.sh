#!/bin/bash
set -euo pipefail

# Install Google Chrome from Google's apt repo, and remove Firefox, which it replaces.
# Adds an apt repo and packages with sudo whatever HOME is: test it in an Ubuntu VM.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"

STEP_OS=ubuntu
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

# Origin and suite from https://dl.google.com/linux/chrome-stable/deb/dists/stable/Release
UNATTENDED_CONF=/etc/apt/apt.conf.d/52dotfiles-google-chrome
# Written by the .deb's postinst
GOOGLE_SOURCES=/etc/apt/sources.list.d/google-chrome.sources
# The .deb re-adds its repo only when this sets repo_add_once="true" (Chromium's apt.include)
CHROME_DEFAULTS=/etc/default/google-chrome
UNATTENDED_CONTENT='// From the dotfiles chrome step: install Chrome updates with the daily security updates
Unattended-Upgrade::Origins-Pattern { "origin=Google LLC,suite=stable"; };'
# Written by the .deb's postinst
GOOGLE_KEYRING=/usr/share/keyrings/google-chrome.gpg
# The primary key's fingerprint, as $GOOGLE_LINUX_KEYS_URL lists it. To re-verify, compare that
# page with gpg --show-keys /usr/share/keyrings/google-chrome.gpg.
GOOGLE_KEY_FPR=EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796
GOOGLE_LINUX_KEYS_URL=https://www.google.com/linuxrepositories/

deb_url() {
    echo "https://dl.google.com/linux/direct/google-chrome-stable_current_$(dpkg --print-architecture).deb"
}

# 200: a .deb exists for this CPU; 404: none; 000: unreachable
deb_status() {
    http_status "$(deb_url)"
}

# Runs under ||, so set -e is off: each command checks its own failure.
install_chrome() {
    local deb status=0
    # Without || return, a failed mktemp makes the cleanup below remove /
    deb="$(mktemp -d)" || return 1
    deb="$deb/google-chrome-stable.deb"
    if ! fetch "$(deb_url)" "$deb" "Chrome's .deb"; then
        rm -rf "$(dirname "$deb")"
        return 1
    fi
    # apt's sandbox user must be able to read the file
    chmod a+rx "$(dirname "$deb")" && chmod a+r "$deb" &&
        apt_get install -y "$@" "$deb" || status=1
    rm -rf "$(dirname "$deb")"
    return "$status"
}

# The .deb's key arrives over TLS alone, and unattended-upgrades trusts it as root. Prints what's
# wrong, or nothing.
google_key_problem() {
    local fingerprint
    fingerprint="$(apt_key_fingerprint "$GOOGLE_KEYRING" | join_lines ', ')"
    [ "$fingerprint" != "$GOOGLE_KEY_FPR" ] || return 0
    echo "$GOOGLE_KEYRING has the fingerprint ${fingerprint:-(none)}, not $GOOGLE_KEY_FPR. If $GOOGLE_LINUX_KEYS_URL lists it, update the step's pinned one; if not, remove the key and $GOOGLE_SOURCES"
}

auto_updates_configured() {
    file_is "$UNATTENDED_CONF" "$UNATTENDED_CONTENT"
}

write_auto_updates() {
    write_root_file "$UNATTENDED_CONF" "$UNATTENDED_CONTENT"
}

allow_repo_readd() {
    local content
    content="$(grep -v '^repo_add_once=' "$CHROME_DEFAULTS" 2>/dev/null || true)"
    write_root_file "$CHROME_DEFAULTS" "${content:+$content
}repo_add_once=\"true\""
}

# A release upgrade disables third-party sources with Enabled: no
google_source_exists() {
    [ -r "$GOOGLE_SOURCES" ] && ! grep -qiE '^Enabled:[[:space:]]*no[[:space:]]*$' "$GOOGLE_SOURCES"
}

readd_google_repo() {
    allow_repo_readd && install_chrome --reinstall || return 1
    google_source_exists && return 0
    echo "  Reinstalling Chrome's .deb didn't add Google's apt repo. Add it by hand:" >&2
    echo "  https://www.google.com/linux/linuxrepositories/" >&2
    return 1
}

# Ubuntu's firefox .deb is a stub that installs the snap; ubuntu-desktop-minimal only recommends it
firefox_removed() {
    ! snap list firefox &>/dev/null && ! apt_installed firefox
}

remove_firefox() {
    if snap list firefox &>/dev/null; then
        sudo snap remove --purge firefox || return 1
    fi
    if apt_installed firefox; then
        apt_get purge -y firefox || return 1
    fi
}

# Installing Chrome isn't an item: it branches on whether a .deb exists for this CPU.
chrome_items() {
    items_reset
    item --sudo "Google's apt source ($GOOGLE_SOURCES)" \
        "Re-add Google's apt repo, which Chrome updates from: set repo_add_once in $CHROME_DEFAULTS and reinstall Google's .deb" \
        google_source_exists readd_google_repo
    item --sudo "Chrome origins allowed in unattended-upgrades ($UNATTENDED_CONF)" \
        "Let unattended-upgrades install Chrome updates: write $UNATTENDED_CONF" auto_updates_configured write_auto_updates
    item --sudo "Firefox removed, since Chrome replaces it" \
        "Remove Firefox, which Chrome replaces: its snap and the firefox .deb that installs it" firefox_removed remove_firefox
}

status_google_key() {
    local label="Google's apt key ($GOOGLE_KEYRING) is the one the step pins" problem
    status_require_cmd gpg "$label" || return 0
    problem="$(google_key_problem)"
    if [ -z "$problem" ]; then
        status_item ok "$label"
    else
        status_item missing "$label: $problem"
    fi
}

status() {
    if apt_installed google-chrome-stable; then
        status_item ok "google-chrome-stable from Google's .deb"
    elif status_require_cmd curl "google-chrome-stable from Google's .deb"; then
        case "$(deb_status)" in
            404)
                status_item skipped "Chrome: Google has no .deb for $(dpkg --print-architecture)"
                return 0
                ;;
            200) status_item missing "google-chrome-stable from Google's .deb" ;;
            *) status_item unknown "google-chrome-stable: couldn't reach dl.google.com to check for its .deb" ;;
        esac
    fi
    chrome_items
    items_status google_source_exists auto_updates_configured
    # Only once Chrome is in, so the machine always has a browser
    if apt_installed google-chrome-stable; then
        items_status firefox_removed
        status_google_key
    fi
    status_result
}

apply() {
    echo "Setting up Google Chrome..."

    if ! apt_installed google-chrome-stable; then
        require_cmd curl || return 1
        case "$(deb_status)" in
            200) ;;
            404)
                echo "  Google has no Chrome .deb for $(dpkg --print-architecture); skipping."
                return 0
                ;;
            *)
                echo "  Couldn't reach dl.google.com to check for Chrome's .deb." >&2
                return 1
                ;;
        esac
    fi
    # Re-adding the repo reinstalls the .deb, so it needs curl too
    if apt_installed google-chrome-stable && ! google_source_exists; then
        require_cmd curl || return 1
    fi
    require_cmd gpg || return 1
    local pending=() result=0 installed=false problem
    ! apt_installed google-chrome-stable || installed=true
    chrome_items
    if "$installed"; then
        items_pending google_source_exists auto_updates_configured firefox_removed
    else
        pending+=("Install google-chrome-stable from Google's .deb, which adds Google's apt repo")
        items_pending auto_updates_configured firefox_removed
    fi
    if [ ${#pending[@]} -gt 0 ] && confirm_sudo_changes "${pending[@]}"; then
        if "$installed"; then
            items_apply google_source_exists auto_updates_configured firefox_removed || result=1
        elif install_chrome; then
            items_apply auto_updates_configured firefox_removed || result=1
        else
            result=1
            items_apply auto_updates_configured || result=1
        fi
        [ "$result" -ne 0 ] || echo "  Applied. A running Chrome keeps the old version until you restart it."
    elif [ ${#pending[@]} -eq 0 ]; then
        echo "  Chrome is already installed and updates automatically."
    fi
    if apt_installed google-chrome-stable; then
        problem="$(google_key_problem)"
        if [ -n "$problem" ]; then
            echo "  Google's apt key isn't the one the step pins: $problem." >&2
            result=1
        fi
    fi
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
