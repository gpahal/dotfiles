#!/bin/bash
set -euo pipefail

# Install Google Chrome on Ubuntu from Google's .deb, which also adds Google's apt repo, and let
# unattended-upgrades install its updates, which the ubuntu step turns on. These need sudo, so the
# step lists what's missing and asks once. It skips when Google has no .deb for this CPU. On macOS,
# the homebrew step installs Chrome as a cask, which updates itself.
#
# A temp HOME doesn't isolate this step, which adds an apt repo and packages with sudo. Test it in
# an Ubuntu VM.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# unattended-upgrades only installs from Ubuntu's own repos unless told otherwise. The origin and
# suite come from Google's Release file:
# https://dl.google.com/linux/chrome-stable/deb/dists/stable/Release
UNATTENDED_CONF=/etc/apt/apt.conf.d/52dotfiles-google-chrome
# Where Chrome's .deb adds Google's repo. Its postinst writes this file and removes any
# google-chrome.list.
GOOGLE_SOURCES=/etc/apt/sources.list.d/google-chrome.sources
# The .deb adds Google's repo on the first install only, and later only when this file sets
# repo_add_once="true", which its postinst then sets back to false. See Chromium's
# chrome/installer/linux/common/apt.include.
CHROME_DEFAULTS=/etc/default/google-chrome
UNATTENDED_CONTENT='// From the dotfiles chrome step: install Chrome updates with the daily security updates
Unattended-Upgrade::Origins-Pattern { "origin=Google LLC,suite=stable"; };'

deb_url() {
    echo "https://dl.google.com/linux/direct/google-chrome-stable_current_$(dpkg --print-architecture).deb"
}

# Print the HTTP status of Chrome's .deb for this CPU: 200 when Google publishes one, 404 when it
# doesn't, and 000 when dl.google.com can't be reached
deb_status() {
    http_status "$(deb_url)"
}

# Download Chrome's .deb and install it. Extra arguments go to apt-get install, e.g. --reinstall.
# main runs it as `install_chrome || ...`, where set -e is off, so each command checks its own
# failure.
install_chrome() {
    local deb status=0
    # Without the || return, a failed mktemp would leave deb at /google-chrome-stable.deb, and the
    # cleanup below would remove /
    deb="$(mktemp -d)" || return 1
    deb="$deb/google-chrome-stable.deb"
    if ! fetch "$(deb_url)" "$deb" "Chrome's .deb"; then
        rm -rf "$(dirname "$deb")"
        return 1
    fi
    # apt needs a path, and its sandbox user must be able to read the file
    chmod a+rx "$(dirname "$deb")" && chmod a+r "$deb" &&
        apt_get install -y "$@" "$deb" || status=1
    rm -rf "$(dirname "$deb")"
    return "$status"
}

auto_updates_configured() {
    file_is "$UNATTENDED_CONF" "$UNATTENDED_CONTENT"
}

# Set repo_add_once="true" in Chrome's defaults file, keeping its other settings, so the next
# install of the .deb adds Google's repo again
allow_repo_readd() {
    local content
    content="$(grep -v '^repo_add_once=' "$CHROME_DEFAULTS" 2>/dev/null || true)"
    write_root_file "$CHROME_DEFAULTS" "${content:+$content
}repo_add_once=\"true\""
}

# Succeeds when the source file Chrome's .deb writes is there and lacks the Enabled: no a release
# upgrade adds. The .deb owns the file's content, so nothing else is checked.
google_source_exists() {
    [ -r "$GOOGLE_SOURCES" ] && ! grep -qiE '^Enabled:[[:space:]]*no[[:space:]]*$' "$GOOGLE_SOURCES"
}

status() {
    if is_macos; then
        status_item skipped "Chrome from Google's apt repo: the homebrew step installs Chrome on macOS"
        return 0
    fi
    if apt_installed google-chrome-stable; then
        status_item ok "google-chrome-stable from Google's .deb"
    elif status_require_cmd curl "google-chrome-stable from Google's .deb"; then
        # A HEAD request, which changes nothing
        case "$(deb_status)" in
            404)
                status_item skipped "Chrome: Google has no .deb for $(dpkg --print-architecture)"
                return 0
                ;;
            200) status_item missing "google-chrome-stable from Google's .deb" ;;
            *) status_item unknown "google-chrome-stable: couldn't reach dl.google.com to check for its .deb" ;;
        esac
    fi
    status_check "Google's apt source ($GOOGLE_SOURCES)" google_source_exists
    status_check "Chrome origins allowed in unattended-upgrades ($UNATTENDED_CONF)" auto_updates_configured
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Setting up Google Chrome..."
    if is_macos; then
        echo "  The homebrew step installs Chrome on macOS; skipping."
        return 0
    fi
    require_supported_os || return 1

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
    # Re-adding Google's repo reinstalls the .deb, which needs a download too
    if apt_installed google-chrome-stable && ! google_source_exists; then
        require_cmd curl || return 1
    fi
    local pending=() result=0
    if ! apt_installed google-chrome-stable; then
        pending+=("Install google-chrome-stable from Google's .deb, which adds Google's apt repo")
    elif ! google_source_exists; then
        pending+=("Re-add Google's apt repo, which Chrome updates from: set repo_add_once in $CHROME_DEFAULTS and reinstall Google's .deb")
    fi
    auto_updates_configured || pending+=("Let unattended-upgrades install Chrome updates: write $UNATTENDED_CONF")
    if [ ${#pending[@]} -gt 0 ] && confirm_sudo_changes "${pending[@]}"; then
        if ! apt_installed google-chrome-stable; then
            install_chrome || result=1
        elif ! google_source_exists; then
            allow_repo_readd && install_chrome --reinstall || result=1
            if [ "$result" -eq 0 ] && ! google_source_exists; then
                echo "  Reinstalling Chrome's .deb didn't add Google's apt repo. Add it by hand:" >&2
                echo "  https://www.google.com/linux/linuxrepositories/" >&2
                result=1
            fi
        fi
        auto_updates_configured || write_root_file "$UNATTENDED_CONF" "$UNATTENDED_CONTENT" || result=1
        [ "$result" -ne 0 ] || echo "  Applied. A running Chrome keeps the old version until you restart it."
    elif [ ${#pending[@]} -eq 0 ]; then
        echo "  Chrome is already installed and updates automatically."
    fi
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
