#!/bin/bash
set -euo pipefail

# Install Homebrew, the formulae and App Store apps in homebrew/Brewfile, and the casks listed
# below. On macOS, also the Xcode Command Line Tools. On Ubuntu, also the apt packages Homebrew
# needs, and only the casks with Linux builds.
#
# A temp HOME doesn't isolate this step, which installs into the real Homebrew prefix and
# /Applications, and on Ubuntu installs apt packages with sudo. Test it in a macOS VM or on a
# spare Mac, and in an Ubuntu VM.
#
# The step makes two exceptions to how steps fail. A new Mac isn't signed in to the App Store yet,
# so when only App Store apps failed, the step warns and passes. Declining the apt packages fails
# the step, unlike other declined confirms, since every later step needs them.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

BREWFILE="$DOTFILES_DIR/homebrew/Brewfile"

# Print each cask brew lists, a tab, and the path of the app it installs, with one brew call for
# them all. The path is empty for a cask with no app, and for every cask off macOS or without jq.
installed_cask_apps() {
    if is_macos && command -v jq &>/dev/null; then
        brew info --json=v2 --installed --cask 2>/dev/null | jq -r ".casks[] | [.token, $CASK_APP_JQ] | @tsv"
    else
        brew list --cask -1 2>/dev/null | awk '{ print $0 "\t" }'
    fi
}

# The apt packages that provide UBUNTU_COMMANDS (lib/common.sh), which Ubuntu needs before
# Homebrew, locales for locale-gen, which the ubuntu step runs to add the en_US.UTF-8 locale, and
# fontconfig for fc-cache, which lets apps find the Monaspace cask's fonts. Minimal images lack them.
UBUNTU_PACKAGES="build-essential procps curl file git zsh lsof bsdextrautils unzip jq locales fontconfig"

CASKS=(
    font-monaspace
    ghostty
    zed
    google-chrome
    orbstack
    tailscale-app
    raycast
    rectangle
    stats
    appcleaner
    the-unarchiver
    logi-options+
    elgato-stream-deck
    hammerspoon
)

# Casks with Linux builds that Ubuntu gets too. Fonts install into $XDG_DATA_HOME/fonts, or
# ~/.local/share/fonts when it isn't set.
UBUNTU_CASKS=(
    font-monaspace
    zed
)

command_line_tools_installed() {
    xcode-select -p &>/dev/null
}

install_command_line_tools() {
    if command_line_tools_installed; then
        echo "Xcode Command Line Tools already installed."
        return 0
    fi
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install || true
    echo "Finish the Command Line Tools install in the dialog that opened, then re-run this script."
    exit 1
}

# Print the UBUNTU_COMMANDS, locale-gen, and fc-cache that are missing, each after a space. Looks
# only outside Homebrew, which lib/common.sh puts on PATH, so its copies (jq, git, zsh) don't
# count: these must keep working if Homebrew breaks.
missing_ubuntu_commands() {
    (
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        for cmd in "${UBUNTU_COMMANDS[@]}" locale-gen fc-cache; do
            command -v "$cmd" &>/dev/null || printf ' %s' "$cmd"
        done
    )
}

install_ubuntu_packages() {
    local missing install="sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $UBUNTU_PACKAGES"
    missing="$(missing_ubuntu_commands)"
    if [ -z "$missing" ]; then
        echo "apt packages already installed."
    else
        # Printed before asking, since confirm prints nothing without a terminal
        echo "Missing commands:$missing"
        # Declining fails the step (see the header)
        if ! confirm "Install them with: $install?"; then
            echo "Install them with: $install"
            echo "Then re-run this script."
            exit 1
        fi
        # shellcheck disable=SC2119 # it passes options on to apt-get update, and needs none here
        apt_get_update || exit 1
        # shellcheck disable=SC2086 # one word per package
        apt_get install -y $UBUNTU_PACKAGES || exit 1
    fi
    if ! locale_installed; then
        echo "  The en_US.UTF-8 locale is missing, so programs will warn about LANG. The ubuntu step"
        echo "  adds it."
    fi
}

# Print the directory the Homebrew installer creates, with sudo
homebrew_prefix() {
    if is_ubuntu; then
        echo /home/linuxbrew/.linuxbrew
    else
        echo /opt/homebrew
    fi
}

install_homebrew() {
    if command -v brew &>/dev/null; then
        echo "Homebrew already installed."
        return 0
    fi
    # The installer needs sudo to create the prefix. Without a terminal it uses sudo -n, which
    # works only when sudo is cached, and otherwise fails late, with "Insufficient permissions"
    # on Ubuntu or "Need sudo access" on macOS.
    if ! is_interactive && [ ! -d "$(homebrew_prefix)" ] && ! sudo_cached; then
        echo "Installing Homebrew needs sudo. Run this step from a terminal: bash setup.sh homebrew" >&2
        return 1
    fi
    echo "Installing Homebrew..."
    run_installer bash https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        "the Homebrew installer" || return 1
    load_brew
}

# --no-upgrade leaves outdated ones to `upgrade`
bundle_installed() {
    brew bundle check --file="$BREWFILE" --no-upgrade &>/dev/null
}

# Run brew bundle <check|install> on everything in the Brewfile but its App Store apps
bundle_except_mas() {
    HOMEBREW_BUNDLE_MAS_SKIP="$(mas_app_ids "$BREWFILE" | tr '\n' ' ')" \
        brew bundle "$1" --file="$BREWFILE" --no-upgrade
}

# Succeeds when everything in the Brewfile but its App Store apps is installed
bundle_installed_except_mas() {
    bundle_except_mas check &>/dev/null
}

# Formulae and App Store apps from the Brewfile
install_bundle() {
    if bundle_installed; then
        if is_macos; then
            echo "Brew formulae and App Store apps already installed."
        else
            echo "Brew formulae already installed."
        fi
    else
        if is_macos; then
            echo "Installing brew formulae and App Store apps..."
        else
            echo "Installing brew formulae..."
        fi
        # Keeps brew's status, so main sees 130 from Ctrl-C
        local status=0
        brew bundle install --file="$BREWFILE" --no-upgrade || status=$?
        if [ "$status" -ne 0 ]; then
            if is_macos && [ "$status" -le 128 ] && mas_app_missing; then
                # On a new Mac, nobody has signed in to the App Store yet, so the App Store apps
                # alone don't fail the step
                if bundle_installed_except_mas; then
                    echo "  Everything else in the Brewfile is installed, but not its App Store apps." >&2
                    status=0
                fi
                echo "  Sign in to the App Store, buy any paid app homebrew/Brewfile lists under mas there once, then re-run." >&2
                echo "  mas installs with sudo, so re-run from a terminal, or after sudo -v." >&2
            fi
            [ "$status" -eq 0 ] || return "$status"
        fi
    fi
}

# Succeeds when an App Store app the Brewfile lists isn't installed, or mas itself isn't
mas_app_missing() {
    local installed id
    installed="$(mas list 2>/dev/null | awk '{ print $1 }')" || return 0
    while read -r id; do
        printf '%s\n' "$installed" | grep -qxF "$id" || return 0
    done < <(mas_app_ids "$BREWFILE")
    return 1
}

# Install a cask, adding it to the caller's failed array when that fails
try_install_cask() {
    install_cask "$@" || failed+=("$1")
}

# Fail after trying every cask, naming the ones that failed, so one failure doesn't skip the rest
report_failed_casks() {
    [ $# -gt 0 ] || return 0
    echo "  These casks failed to install: $*. Fix the errors above and re-run." >&2
    return 1
}

# Print the casks this OS gets: CASKS on macOS, UBUNTU_CASKS on Ubuntu
os_casks() {
    if is_macos; then
        printf '%s\n' "${CASKS[@]}"
    else
        printf '%s\n' "${UBUNTU_CASKS[@]}"
    fi
}

# Install the casks this OS gets that brew doesn't list, and reinstall those whose app was deleted.
# An app installed outside Homebrew counts as installed; status says so. scripts/upgrade.sh runs it
# too, for casks added since setup ran.
install_casks() {
    local cask state app apps installing=false failed=()
    # One brew call for every cask: each lookup takes a moment
    apps="$(installed_cask_apps || true)"
    for cask in $(os_casks); do
        IFS=$'\t' read -r state app <<< "$(cask_state "$cask" "" "$apps")"
        case "$state" in brew | other) continue ;; esac
        "$installing" || echo "Installing brew casks..."
        installing=true
        try_install_cask "$cask" "$app"
    done
    if ! "$installing"; then
        echo "Brew casks already installed."
    elif ! is_macos && command -v fc-cache &>/dev/null; then
        # Homebrew copies fonts in but doesn't refresh fontconfig's cache, so apps wouldn't see them
        fc-cache -f "${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
    fi
    report_failed_casks ${failed[@]+"${failed[@]}"}
}

status() {
    local missing cask bundle apps
    if is_macos; then
        status_check "Xcode Command Line Tools" command_line_tools_installed
        status_item skipped "apt packages Homebrew needs: Ubuntu only"
    else
        status_item skipped "Xcode Command Line Tools: macOS only"
        missing="$(missing_ubuntu_commands)"
        if [ -z "$missing" ]; then
            status_item ok "apt packages Homebrew needs"
        else
            status_item missing "apt packages Homebrew needs; missing commands:$missing"
        fi
    fi
    if ! command -v brew &>/dev/null; then
        status_item missing "Homebrew"
        status_item unknown "Brewfile and casks: Homebrew isn't installed"
        status_result
        return
    fi
    status_item ok "Homebrew"
    bundle="Brewfile brew formulae"
    # brew bundle check is the slowest check of any step
    if [ "${DOTFILES_STATUS_QUICK:-}" == 1 ]; then
        status_item unverified "$bundle (skipped by --quick; run status without it to check)"
    else
        status_check "$bundle" bundle_installed_except_mas
    fi
    if is_macos; then
        if mas_app_missing; then
            status_item missing "Brewfile App Store apps (sign in to the App Store, buy the paid ones there once, then re-run the homebrew step)"
        else
            status_item ok "Brewfile App Store apps"
        fi
    else
        status_item skipped "Brewfile App Store apps: macOS only"
    fi
    # One brew call for every cask, rather than one each, which took seconds
    apps="$(installed_cask_apps || true)"
    for cask in $(os_casks); do
        status_cask "$cask" "" "$apps"
    done
    is_macos || status_item skipped "Other casks: they have no Linux builds"
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    require_supported_os || return 1
    if is_macos; then
        install_command_line_tools
    else
        install_ubuntu_packages
    fi
    install_homebrew
    # Install the casks even when the bundle fails, e.g. on an App Store app not yet owned
    local bundle_status=0 casks_status=0
    install_bundle || bundle_status=$?
    # Ctrl-C, which brew catches
    [ "$bundle_status" -le 128 ] || return "$bundle_status"
    install_casks || casks_status=$?
    [ "$bundle_status" -eq 0 ] || return "$bundle_status"
    return "$casks_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
