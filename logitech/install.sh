#!/bin/bash
set -euo pipefail

# Install Solaar in place of Logi Options+, and give it the MX Master 4's Mac settings.
# Options+ has no Linux version, so Solaar comes from its team's PPA. The mouse's settings are in
# mx-master-4.yaml, and its buttons' actions in solaar-rules.yaml.
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
        solaar_pinned "write_root_content SOLAAR_PIN SOLAAR_PIN_CONTENT 0644"
    item --sudo "The Solaar team's PPA" "Add the Solaar team's PPA ($SOLAAR_SOURCES)" \
        solaar_source_ok add_solaar_repo
    item --sudo --hint "older ones fail every settings change after the USB switch replugs the receiver" \
        "Solaar $SOLAAR_MIN_VERSION or later" "Install Solaar from the Solaar team's PPA" \
        solaar_current install_solaar
}

# Solaar keeps its config.yaml in memory and writes all of it back, so it only reads an edit made
# while it's quit, when it next starts. rules.yaml it reads at start, and writes from its rule
# editor.
SOLAAR_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/solaar"
SOLAAR_CONFIG="$SOLAAR_CONFIG_DIR/config.yaml"
SOLAAR_RULES="$SOLAAR_CONFIG_DIR/rules.yaml"
MOUSE_SETTINGS="$DOTFILES_DIR/logitech/mx-master-4.yaml"
MOUSE_RULES="$DOTFILES_DIR/logitech/solaar-rules.yaml"
# How Solaar names the MX Master 4 in config.yaml, whichever receiver or Bluetooth it came through.
# An entry with only this ID matches any MX Master 4, so one Solaar hasn't seen yet gets one.
MOUSE_MODEL_ID=B04200000000
# The yq expressions read the settings, without their comments, from $settings
MOUSE_ENTRIES='.[] | select(type == "!!map" and ._modelId == "'"$MOUSE_MODEL_ID"'")'
MOUSE_SETTINGS_YQ='(load(strenv(settings)) | ... comments = "")'

solaar_running() {
    pgrep -x solaar &>/dev/null
}

# Every MX Master 4 entry has the repo's settings, and there's at least one
mouse_settings_set() {
    settings="$MOUSE_SETTINGS" yq -e "([$MOUSE_ENTRIES] | length) > 0 and
        ([$MOUSE_ENTRIES | select((. * $MOUSE_SETTINGS_YQ | to_json(0)) != to_json(0))] | length) == 0" \
        "$SOLAAR_CONFIG" &>/dev/null
}

# For merge_file: the config on stdin with the settings merged into each MX Master 4 entry, or an
# entry added. Solaar takes the first item as the version that wrote the file, and on a mismatch
# only detects the mouse's features again.
merge_mouse_settings() {
    local input
    input="$(cat)"
    [[ "$input" =~ [^[:space:]] ]] || input="- \"$(solaar_version || echo 0)\""
    if ! printf '%s\n' "$input" | settings="$MOUSE_SETTINGS" yq "$MOUSE_SETTINGS_YQ as \$s |
        if ([$MOUSE_ENTRIES] | length) > 0 then ($MOUSE_ENTRIES) *= \$s
        else . += [{\"_modelId\": \"$MOUSE_MODEL_ID\", \"_NAME\": \"MX Master 4\"} * \$s] end" -; then
        echo "  Couldn't edit $1 with yq; is it a list, as Solaar writes it?" >&2
        return 1
    fi
}

set_mouse_settings() {
    if solaar_running; then
        echo "  Solaar is running and would overwrite $(shown_path "$SOLAAR_CONFIG"), so the MX Master 4's"
        echo "  settings weren't written. Quit Solaar from its menu, re-run this step, then open Solaar."
        return 0
    fi
    mkdir -p "$SOLAAR_CONFIG_DIR" && merge_file "$SOLAAR_CONFIG" merge_mouse_settings || return 1
    echo "  Set the MX Master 4's settings in $(shown_path "$SOLAAR_CONFIG"). Open Solaar to apply them."
}

mouse_rules_copied() {
    cmp -s "$MOUSE_RULES" "$SOLAAR_RULES"
}

copy_mouse_rules() {
    copy_file "$MOUSE_RULES" "$SOLAAR_RULES" || return 1
    if solaar_running; then
        echo "  Solaar reads them when it starts, so quit it from its menu and open it again."
    fi
}

mouse_items() {
    items_reset
    item "The MX Master 4's settings in $(shown_path "$SOLAAR_CONFIG")" \
        "Set the MX Master 4's settings" mouse_settings_set set_mouse_settings
    item "Solaar rules for the MX Master 4's buttons ($(shown_path "$SOLAAR_RULES"))" \
        "Copy the MX Master 4's button rules" mouse_rules_copied copy_mouse_rules
}

status() {
    logitech_items
    items_status solaar_pinned
    status_apt_source "The Solaar team's PPA" "$SOLAAR_SOURCES" "$(solaar_sources)" logitech "$(apt_release_url "$SOLAAR_PPA")"
    items_status solaar_current
    status_require_cmd yq "The MX Master 4's settings and button rules" || return 0
    mouse_items
    items_status
}

apply() {
    echo "Setting up Logitech devices..."
    require_cmd yq || return 1
    # Without the PPA for this release, the next run adds it, and Ubuntu's Solaar stands in
    local wanted=(solaar_pinned solaar_source_ok solaar_current) result=0
    if ! solaar_source_ok; then
        require_cmd curl || return 1
        if apt_repo_published "The Solaar team's PPA" "$(apt_release_url "$SOLAAR_PPA")"; then
            # add_apt_repo needs it; fail before the pin goes in
            require_cmd gpg || return 1
        elif apt_installed solaar; then
            wanted=()
        else
            wanted=(solaar_current)
        fi
    fi
    if [ ${#wanted[@]} -gt 0 ]; then
        logitech_items
        items_apply_confirmed --done "  Solaar $(solaar_version) is already installed." "${wanted[@]}" ||
            result=1
    fi
    mouse_items
    items_apply || result=1
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
