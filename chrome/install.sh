#!/bin/bash
set -euo pipefail

# Install Google Chrome from Google's apt repo, and remove Firefox, which it replaces.
# Adds an apt repo and packages with sudo whatever HOME is: test it in an Ubuntu VM.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"

STEP_OS=ubuntu
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

# Origin and suite from https://dl.google.com/linux/chrome-stable/deb/dists/stable/Release
UNATTENDED_CONF=/etc/apt/apt.conf.d/52dotfiles-google-chrome
# The path Chrome's own cron job writes its source to, so the two never both exist
GOOGLE_SOURCES=/etc/apt/sources.list.d/google-chrome.sources
# Chrome's postinst creates this with repo_add_once="true" when it's missing, and its cron job then
# rewrites $GOOGLE_SOURCES. The step sets it to "false" first.
CHROME_DEFAULTS=/etc/default/google-chrome
UNATTENDED_CONTENT='// From the dotfiles chrome step: install Chrome updates with the daily security updates
Unattended-Upgrade::Origins-Pattern { "origin=Google LLC,suite=stable"; };'
GOOGLE_KEYRING=/usr/share/keyrings/google-chrome.gpg
GOOGLE_KEY_URL=https://dl.google.com/linux/linux_signing_key.pub
# Primary key fingerprint from $GOOGLE_LINUX_KEYS_URL; recheck with gpg --show-keys $GOOGLE_KEYRING
GOOGLE_KEY_FPR=EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796
GOOGLE_LINUX_KEYS_URL=https://www.google.com/linuxrepositories/
# Google's suite is stable for every release, so not deb822_source's codename. Google builds Chrome
# for amd64 alone.
GOOGLE_SOURCES_CONTENT="Types: deb
URIs: https://dl.google.com/linux/chrome-stable/deb/
Suites: stable
Components: main
Architectures: amd64
Signed-By: $GOOGLE_KEYRING"

# Google's key arrives over TLS alone, and unattended-upgrades trusts it as root. Prints what's
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

# Else Chrome's postinst and cron job would rewrite $GOOGLE_SOURCES. Keeps your other settings.
stop_repo_readd() {
    local content
    ! grep -qx 'repo_add_once="false"' "$CHROME_DEFAULTS" 2>/dev/null || return 0
    content="$(grep -v '^repo_add_once=' "$CHROME_DEFAULTS" 2>/dev/null || true)"
    write_root_file "$CHROME_DEFAULTS" "${content:+$content
}repo_add_once=\"false\""
}

# A release upgrade disables third-party sources with Enabled: no
google_source_exists() {
    [ -r "$GOOGLE_SOURCES" ] && ! grep -qiE '^Enabled:[[:space:]]*no[[:space:]]*$' "$GOOGLE_SOURCES"
}

add_google_repo() {
    stop_repo_readd || return 1
    add_apt_repo Google "$GOOGLE_SOURCES" "$GOOGLE_SOURCES_CONTENT" "$GOOGLE_KEY_URL" "$GOOGLE_KEYRING" \
        "$GOOGLE_KEY_FPR"
}

# Ubuntu's firefox .deb is a stub that installs the snap; ubuntu-desktop-minimal only recommends it
firefox_removed() {
    ! snap list firefox &>/dev/null && ! apt_installed firefox
}

# Only once Chrome is in, so the machine always has a browser
remove_firefox() {
    if ! apt_installed google-chrome-stable; then
        echo "  Firefox stays until Chrome is installed." >&2
        return 1
    fi
    if snap list firefox &>/dev/null; then
        sudo snap remove --purge firefox || return 1
    fi
    if apt_installed firefox; then
        apt_get purge -y firefox || return 1
    fi
}

# Needs Google's source, which the item before adds
install_chrome() {
    google_source_exists && stop_repo_readd && apt_install_fresh google-chrome-stable
}

# Installing Chrome is apply-only, since status reports it on its own: apply skips a CPU Google
# doesn't build for before declaring the items.
chrome_items() {
    items_reset
    item --sudo "Google's apt source ($GOOGLE_SOURCES)" \
        "Add Google's apt repo, which Chrome updates from, with its pinned key: write $GOOGLE_SOURCES" \
        google_source_exists add_google_repo
    item --sudo "" "Install google-chrome-stable from Google's apt repo, with repo_add_once=\"false\" in $CHROME_DEFAULTS so it leaves the source alone" \
        "apt_installed google-chrome-stable" install_chrome
    item --sudo "Chrome origins allowed in unattended-upgrades ($UNATTENDED_CONF)" \
        "Let unattended-upgrades install Chrome updates: write $UNATTENDED_CONF" \
        auto_updates_configured "write_root_content UNATTENDED_CONF UNATTENDED_CONTENT"
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
    local arch
    if apt_installed google-chrome-stable; then
        status_item ok "google-chrome-stable from Google's apt repo"
    else
        arch="$(dpkg --print-architecture)"
        if [ "$arch" != amd64 ]; then
            status_item skipped "Chrome: Google has no .deb for $arch"
            return 0
        fi
        status_item missing "google-chrome-stable from Google's apt repo"
    fi
    chrome_items
    items_status google_source_exists auto_updates_configured
    # Only once Chrome is in, so the machine always has a browser
    if apt_installed google-chrome-stable; then
        items_status firefox_removed
        status_google_key
    fi
}

apply() {
    echo "Setting up Google Chrome..."

    local result=0 installed=false problem arch
    ! apt_installed google-chrome-stable || installed=true
    if ! "$installed"; then
        arch="$(dpkg --print-architecture)"
        if [ "$arch" != amd64 ]; then
            echo "  Google has no Chrome .deb for $arch; skipping."
            return 0
        fi
    fi
    # add_apt_repo downloads the key with curl
    if ! google_source_exists; then
        require_cmd curl || return 1
    fi
    require_cmd gpg || return 1
    chrome_items
    items_apply_confirmed --done "  Chrome is already installed and updates automatically." || result=1
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
