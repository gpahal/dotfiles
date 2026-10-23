#!/bin/bash
set -euo pipefail

# Install Homebrew, the Brewfile's formulae, and the step's casks and App Store apps.
# Installs into the real Homebrew prefix whatever HOME is: test it in a VM or on a spare machine.
# Rule breaks: failed App Store apps only warn (a new Mac isn't signed in), and declining the apt
# packages fails the step, since every later step needs them.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"

BREWFILE="$DOTFILES_DIR/homebrew/Brewfile"

# "<id> <name> [optional]": a missing optional app is only reported.
MAS_APPS=(
    "937984704 Amphetamine"       # Keeps the Mac awake
    "1470584107 Dato optional"    # Menu bar calendar
    "1295203466 Windows App"      # Microsoft's RDP client, for the Ubuntu desktop's GNOME Remote Login
)

# Prints "<cask>\t<app path>"; the path is empty off macOS, without jq, or for a cask with no app.
installed_cask_apps() {
    if is_macos && command -v jq &>/dev/null; then
        brew info --json=v2 --installed --cask 2>/dev/null | jq -r ".casks[] | [.token, $CASK_APP_JQ] | @tsv"
    else
        brew list --cask -1 2>/dev/null | awk '{ print $0 "\t" }'
    fi
}

# UBUNTU_COMMANDS (lib/common.sh), plus locale-gen and fc-cache, which minimal images lack, and
# wl-copy, which gh auth login copies its one-time code with on the desktop
UBUNTU_PACKAGES="build-essential procps curl file git zsh lsof bsdextrautils unzip jq gpg locales fontconfig wl-clipboard"

# One per line: scripts/check-brew-packages.sh parses it
CASKS=(
    font-monaspace      # Monaspace, the terminal and editor font
    ghostty             # Terminal; Ubuntu gets its snap from the ghostty step
    zed                 # Editor
    google-chrome       # Browser, which the AI tools also control; Ubuntu gets it from the chrome step
    orbstack            # Docker containers and Linux machines
    tailscale-app       # Private network to reach the Ubuntu machine from anywhere
    vicinae             # Launcher, with the vicinae step's settings; Ubuntu gets it from that step
    rectangle           # Window management
    appcleaner          # App uninstaller
    the-unarchiver      # Opens any archive format
    logi-options+       # Logitech device settings; Ubuntu gets Solaar from the logitech step
    elgato-stream-deck  # Stream Deck keys, with the stream-deck step's plugin
    hammerspoon         # The hotkeys the hammerspoon step sets
)

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

# Ignores Homebrew's copies: these must keep working if Homebrew breaks.
missing_ubuntu_commands() {
    (
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        for cmd in "${UBUNTU_COMMANDS[@]}" locale-gen fc-cache wl-copy; do
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
        # confirm prints nothing without a terminal
        echo "Missing commands:$missing"
        if ! confirm "Install them with: $install?"; then
            echo "Install them with: $install"
            echo "Then re-run this script."
            exit 1
        fi
        # shellcheck disable=SC2086 # one word per package
        apt_install_fresh $UBUNTU_PACKAGES || exit 1
    fi
    if ! locale_installed; then
        echo "  The en_US.UTF-8 locale is missing, so programs will warn about LANG. The ubuntu step"
        echo "  adds it."
    fi
}

homebrew_prefix() {
    if is_ubuntu; then
        echo "${HOMEBREW_PREFIXES[1]}"
    else
        echo "${HOMEBREW_PREFIXES[0]}"
    fi
}

install_homebrew() {
    if command -v brew &>/dev/null; then
        echo "Homebrew already installed."
        return 0
    fi
    # Without a terminal the installer uses sudo -n, which fails late unless sudo is cached
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

install_bundle() {
    if bundle_installed; then
        echo "Brew formulae already installed."
        return 0
    fi
    echo "Installing brew formulae..."
    brew bundle install --file="$BREWFILE" --no-upgrade
}

# Prints "<required|optional> <id> <name>" per missing app
missing_mas_apps() {
    local installed entry id name kind
    installed="$(mas list 2>/dev/null | awk '{ print $1 }')" || installed=""
    for entry in "${MAS_APPS[@]}"; do
        id="${entry%% *}" name="${entry#* }" kind=required
        if [[ "$name" == *" optional" ]]; then
            name="${name% optional}" kind=optional
        fi
        printf '%s\n' "$installed" | grep -qxF "$id" || printf '%s %s %s\n' "$kind" "$id" "$name"
    done
}

# A failed required app only warns. Returns an interrupted mas's status, so apply stops.
install_mas_apps() {
    local missing kind id name status failed=() optional=()
    missing="$(missing_mas_apps)"
    if [ -z "$missing" ]; then
        echo "App Store apps already installed."
        return 0
    fi
    if ! command -v mas &>/dev/null; then
        echo "  mas isn't installed, so the App Store apps can't be. Install the Brewfile, then re-run." >&2
        return 1
    fi
    echo "Installing App Store apps..."
    # fd 3 keeps stdin free for sudo's password prompt
    while read -r -u 3 kind id name; do
        status=0
        mas install "$id" || status=$?
        if [ "$status" -ne 0 ] && [ "$kind" == required ] && ! interrupted_status "$status"; then
            status=0
            mas get "$id" || status=$?
        fi
        ! interrupted_status "$status" || return "$status"
        [ "$status" -eq 0 ] && continue
        if [ "$kind" == required ]; then
            failed+=("$name")
        else
            optional+=("$name")
        fi
    done 3<<< "$missing"
    if [ ${#failed[@]} -gt 0 ]; then
        echo "  Couldn't install from the App Store: $(printf '%s\n' "${failed[@]}" | join_lines ', ')." >&2
        echo "  Sign in to the App Store, buy any paid app MAS_APPS in homebrew/install.sh lists there once, then re-run." >&2
        echo "  mas installs with sudo, so re-run from a terminal, or after sudo -v." >&2
    fi
    if [ ${#optional[@]} -gt 0 ]; then
        echo "  Not installed, and optional: $(printf '%s\n' "${optional[@]}" | join_lines ', '). To add one, buy it in the App Store, then re-run."
    fi
}

os_casks() {
    if is_macos; then
        printf '%s\n' "${CASKS[@]}"
    else
        printf '%s\n' "${UBUNTU_CASKS[@]}"
    fi
}

# Also run by scripts/upgrade.sh. An app installed outside Homebrew counts as installed.
install_casks() {
    local cask state app apps installing=false failed=()
    apps="$(installed_cask_apps || true)"
    for cask in $(os_casks); do
        IFS=$'\t' read -r state app <<< "$(cask_state "$cask" "" "$apps")"
        case "$state" in brew | other) continue ;; esac
        "$installing" || echo "Installing brew casks..."
        installing=true
        install_cask "$cask" "$app" "$state" || failed+=("$cask")
    done
    if ! "$installing"; then
        echo "Brew casks already installed."
    elif ! is_macos && command -v fc-cache &>/dev/null; then
        # Homebrew doesn't refresh fontconfig's cache
        fc-cache -f "${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
    fi
    [ ${#failed[@]} -eq 0 ] && return 0
    echo "  These casks failed to install: ${failed[*]}. Fix the errors above and re-run." >&2
    return 1
}

status() {
    local missing cask bundle apps app mas_missing kind
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
        return 0
    fi
    status_item ok "Homebrew"
    bundle="Brewfile brew formulae"
    if status_for_alerts; then
        status_item unverified "$bundle (skipped by --for-alerts; run status without it to check)"
    else
        status_check "$bundle" bundle_installed
    fi
    if is_macos && status_require_cmd mas "App Store apps"; then
        mas_missing="$(missing_mas_apps)"
        if grep -q '^required ' <<< "$mas_missing"; then
            status_item missing "App Store apps (sign in to the App Store, buy the paid ones there once, then re-run the homebrew step)"
        else
            status_item ok "App Store apps"
        fi
        while read -r kind _ app; do
            [ "$kind" != optional ] ||
                status_item info "$app (App Store) isn't installed. It's optional: to add it, buy it in the App Store, then re-run the homebrew step"
        done <<< "$mas_missing"
    elif ! is_macos; then
        status_item skipped "App Store apps: macOS only"
    fi
    apps="$(installed_cask_apps || true)"
    for cask in $(os_casks); do
        status_cask "$cask" "" "$apps"
    done
    is_macos || status_item skipped "Other casks: they have no Linux builds"
}

apply() {
    require_supported_os || return 1
    if is_macos; then
        install_command_line_tools
    else
        install_ubuntu_packages
    fi
    install_homebrew
    # Keep going past failures, but stop at Ctrl-C (brew and mas exit above 128)
    local parts=(install_bundle) part result status=0
    if is_macos; then
        parts+=(install_mas_apps)
    fi
    parts+=(install_casks)
    for part in "${parts[@]}"; do
        result=0
        "$part" || result=$?
        [ "$result" -le 128 ] || return "$result"
        [ "$status" -ne 0 ] || status="$result"
    done
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
