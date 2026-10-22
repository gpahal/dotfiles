#!/bin/bash
set -euo pipefail

# Install Solaar from the Solaar team's PPA, since Logi Options+ has no Linux version.
# Installs a package with sudo whatever HOME is: test it in an Ubuntu VM.
# Ubuntu's Solaar 1.1.19 fails every settings change after the USB switch replugs the receiver
# (pwr-Solaar/Solaar#3245), so this takes 1.1.20 or later from the PPA, and only Solaar.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"

STEP_OS=ubuntu

SOLAAR_MIN_VERSION=1.1.20
SOLAAR_PPA=https://ppa.launchpadcontent.net/solaar-unifying/stable/ubuntu
SOLAAR_KEYRING=/etc/apt/keyrings/solaar.asc
# The PPA's signing key, which Launchpad lists for ~solaar-unifying/+archive/ubuntu/stable
SOLAAR_KEY_FPR=643FF34AF9151DC814DD3A1B2303D595EE907473
SOLAAR_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$SOLAAR_KEY_FPR"
SOLAAR_SOURCES=/etc/apt/sources.list.d/solaar.sources
SOLAAR_PIN=/etc/apt/preferences.d/dotfiles-solaar
# Origin from $SOLAAR_PPA/dists/<codename>/Release. -1 keeps apt from taking any other package
# from the PPA; the solaar entry, being specific, overrides it.
SOLAAR_PIN_CONTENT='Explanation: From the dotfiles logitech step: take only Solaar from the Solaar team'"'"'s PPA
Package: *
Pin: release o=LP-PPA-solaar-unifying-stable
Pin-Priority: -1

Package: solaar
Pin: release o=LP-PPA-solaar-unifying-stable
Pin-Priority: 500'

solaar_sources() {
    cat <<EOF
Types: deb
URIs: $SOLAAR_PPA
Suites: $(ubuntu_codename)
Components: main
Signed-By: $SOLAAR_KEYRING
EOF
}

# 404 until the PPA publishes packages for this release
solaar_release_url() {
    echo "$SOLAAR_PPA/dists/$(ubuntu_codename)/Release"
}

# The upstream part of the installed version: 1.1.20 from 1.1.20+202607061356~ubuntu26.04.1
solaar_version() {
    local version
    version="$(dpkg-query -W -f='${Version}' solaar 2>/dev/null)" || return 1
    [[ "$version" =~ ^([0-9]+:)?([0-9]+(\.[0-9]+)*) ]] || return 1
    echo "${BASH_REMATCH[2]}"
}

solaar_current() {
    local version
    apt_installed solaar && version="$(solaar_version)" && version_at_least "$version" "$SOLAAR_MIN_VERSION"
}

solaar_pinned() {
    file_is "$SOLAAR_PIN" "$SOLAAR_PIN_CONTENT"
}

write_solaar_pin() {
    write_root_file "$SOLAAR_PIN" "$SOLAAR_PIN_CONTENT" 0644
}

solaar_source_ok() {
    file_is "$SOLAAR_SOURCES" "$(solaar_sources)"
}

add_solaar_repo() {
    add_apt_repo "The Solaar team's PPA" "$SOLAAR_SOURCES" "$(solaar_sources)" "$SOLAAR_KEY_URL" \
        "$SOLAAR_KEYRING" "$SOLAAR_KEY_FPR"
}

# Runs where set -e is off: each command checks its own failure.
install_solaar() {
    # Stale lists can name a version the mirror no longer has
    apt_get_update || return 1
    apt_get install -y solaar || return 1
    echo "  Installed Solaar $(solaar_version). It starts with your desktop session; if it's running, quit it and open it again."
}

# Order matters: the pin goes before the source, so apt never sees the PPA unpinned.
logitech_items() {
    items_reset
    item --sudo "Only Solaar taken from the Solaar team's PPA ($SOLAAR_PIN)" \
        "Let apt take only Solaar from the Solaar team's PPA: write $SOLAAR_PIN" \
        solaar_pinned write_solaar_pin
    item --sudo "The Solaar team's PPA" "Add the Solaar team's PPA ($SOLAAR_SOURCES)" \
        solaar_source_ok add_solaar_repo
    item --sudo --hint "older ones fail every settings change after the USB switch replugs the receiver" \
        "Solaar $SOLAAR_MIN_VERSION or later" "Install Solaar from the Solaar team's PPA" \
        solaar_current install_solaar
}

status() {
    logitech_items
    items_status solaar_pinned
    status_apt_source "The Solaar team's PPA" "$SOLAAR_SOURCES" "$(solaar_sources)" logitech "$(solaar_release_url)"
    items_status solaar_current
    status_result
}

apply() {
    echo "Setting up Logitech devices..."
    # Without the PPA for this release, the next run adds it, and Ubuntu's Solaar stands in
    local pending=() wanted=(solaar_pinned solaar_source_ok solaar_current)
    if ! solaar_source_ok; then
        require_cmd curl || return 1
        if apt_repo_published "The Solaar team's PPA" "$(solaar_release_url)"; then
            # add_apt_repo needs it; fail before the pin goes in
            require_cmd gpg || return 1
        else
            wanted=(solaar_current)
            ! apt_installed solaar || return 0
        fi
    fi
    logitech_items
    items_pending "${wanted[@]}"
    if [ ${#pending[@]} -eq 0 ]; then
        echo "  Solaar $(solaar_version) is already installed."
        return 0
    fi
    confirm_sudo_changes "${pending[@]}" || return 0
    items_apply "${wanted[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
