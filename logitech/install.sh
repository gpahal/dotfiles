#!/bin/bash
set -euo pipefail

# Install Solaar from the Solaar team's PPA, since Logi Options+ has no Linux version.
# Installs a package with sudo whatever HOME is: test it in an Ubuntu VM.
# Ubuntu's Solaar 1.1.19 fails every settings change after the USB switch replugs the receiver
# (pwr-Solaar/Solaar#3245), so this takes 1.1.20 or later from the PPA, and only Solaar.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"

STEP_OS=ubuntu
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

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
    deb822_source "$SOLAAR_PPA" main "$SOLAAR_KEYRING"
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

# pin_missing <what happens instead>. Without the pin, apt would take any package the PPA
# publishes, as root through unattended-upgrades.
pin_missing() {
    solaar_pinned && return 1
    echo "  $SOLAAR_PIN isn't in place, so the Solaar team's PPA $1. Fix the error above and re-run." >&2
}

add_solaar_repo() {
    ! pin_missing "wasn't added" || return 1
    add_apt_repo "The Solaar team's PPA" "$SOLAAR_SOURCES" "$(solaar_sources)" "$SOLAAR_KEY_URL" \
        "$SOLAAR_KEYRING" "$SOLAAR_KEY_FPR"
}

# Runs where set -e is off: each command checks its own failure.
install_solaar() {
    if [ -e "$SOLAAR_SOURCES" ] && pin_missing "isn't used"; then
        return 1
    fi
    apt_install_fresh solaar || return 1
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
    status_apt_source "The Solaar team's PPA" "$SOLAAR_SOURCES" "$(solaar_sources)" logitech "$(apt_release_url "$SOLAAR_PPA")"
    items_status solaar_current
}

apply() {
    echo "Setting up Logitech devices..."
    # Without the PPA for this release, the next run adds it, and Ubuntu's Solaar stands in
    local wanted=(solaar_pinned solaar_source_ok solaar_current)
    if ! solaar_source_ok; then
        require_cmd curl || return 1
        if apt_repo_published "The Solaar team's PPA" "$(apt_release_url "$SOLAAR_PPA")"; then
            # add_apt_repo needs it; fail before the pin goes in
            require_cmd gpg || return 1
        else
            wanted=(solaar_current)
            ! apt_installed solaar || return 0
        fi
    fi
    logitech_items
    if items_ok "${wanted[@]}"; then
        echo "  Solaar $(solaar_version) is already installed."
        return 0
    fi
    items_apply_confirmed "${wanted[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
