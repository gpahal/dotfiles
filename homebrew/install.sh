#!/bin/bash
set -euo pipefail

# Install Homebrew and the formulae, casks, and App Store apps the step lists.
#
# Also the Xcode Command Line Tools on macOS, and on Ubuntu the apt packages Homebrew needs.
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
# shellcheck source=../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"

BREWFILE="$DOTFILES_DIR/homebrew/Brewfile"

# The App Store apps macOS gets, as "<id> <name>", and "optional" after a paid app you may not
# buy. An optional app that isn't installed is information in status and the step's output, not
# something to fix.
MAS_APPS=(
    "937984704 Amphetamine"       # Keeps the Mac awake
    "1470584107 Dato optional"    # Menu bar calendar
    "1295203466 Windows App"      # Microsoft's RDP client, for the Ubuntu desktop's GNOME Remote Login
)

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
UBUNTU_PACKAGES="build-essential procps curl file git zsh lsof bsdextrautils unzip jq gpg locales fontconfig"

# The casks macOS gets, one per line, which scripts/check-brew-packages.sh reads
CASKS=(
    font-monaspace      # Monaspace, the terminal and editor font
    ghostty             # Terminal; Ubuntu gets its snap from the ghostty step
    zed                 # Editor
    google-chrome       # Browser, which the AI tools also control; Ubuntu gets it from the chrome step
    orbstack            # Docker containers and Linux machines
    tailscale-app       # Private network to reach the Ubuntu machine from anywhere
    raycast             # Launcher
    rectangle           # Window management
    stats               # Menu bar memory pressure, CPU, GPU, network, and sensors
    appcleaner          # App uninstaller
    the-unarchiver      # Opens any archive format
    logi-options+       # Logitech device settings; Ubuntu gets Solaar from the logitech step
    elgato-stream-deck  # Stream Deck keys, with the stream-deck step's plugin
    hammerspoon         # The hotkeys the hammerspoon step sets
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

install_bundle() {
    if bundle_installed; then
        echo "Brew formulae already installed."
        return 0
    fi
    echo "Installing brew formulae..."
    brew bundle install --file="$BREWFILE" --no-upgrade
}

# Print "<required|optional> <id> <name>" for each of MAS_APPS that isn't installed, one per line,
# with one mas list for them all. Without mas, that's all of them.
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

# Install the App Store apps that aren't, as brew bundle would: mas install for an app the Apple
# Account has, then, for a required one, mas get for a free one it doesn't. A required app that
# fails only warns (see the header), and an optional one is only a note. An optional app gets one
# mas install every run, so it installs once an Apple Account that owns it signs in. Returns the
# status of an interrupted mas, so apply stops.
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
    # fd 3, so mas keeps the terminal as stdin for sudo's password prompt
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

# Install the casks this OS gets that brew doesn't list, and reinstall those whose app was deleted.
# An app installed outside Homebrew counts as installed; status says so. scripts/upgrade.sh runs it
# too, for casks added since setup ran.
install_casks() {
    local cask state app apps installing=false failed=()
    apps="$(installed_cask_apps || true)"
    for cask in $(os_casks); do
        IFS=$'\t' read -r state app <<< "$(cask_state "$cask" "" "$apps")"
        case "$state" in brew | other) continue ;; esac
        "$installing" || echo "Installing brew casks..."
        installing=true
        # The state spares install_cask asking brew again
        install_cask "$cask" "$app" "$state" || failed+=("$cask")
    done
    if ! "$installing"; then
        echo "Brew casks already installed."
    elif ! is_macos && command -v fc-cache &>/dev/null; then
        # Homebrew copies fonts in but doesn't refresh fontconfig's cache, so apps wouldn't see them
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
        status_result
        return
    fi
    status_item ok "Homebrew"
    bundle="Brewfile brew formulae"
    # brew bundle check is the slowest check of any step
    if status_quick; then
        status_item unverified "$bundle (skipped by --quick; run status without it to check)"
    else
        status_check "$bundle" bundle_installed
    fi
    # Without mas, which the Brewfile installs, every app would read as missing for want of an App
    # Store sign-in
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
    status_result
}

apply() {
    require_supported_os || return 1
    if is_macos; then
        install_command_line_tools
    else
        install_ubuntu_packages
    fi
    install_homebrew
    # Install the App Store apps and casks even when the bundle fails, but stop at Ctrl-C, which
    # brew and mas catch, exiting above 128. The step fails with the first failure's status.
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
