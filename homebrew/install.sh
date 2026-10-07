#!/bin/bash
set -euo pipefail

# Install the Xcode Command Line Tools, Homebrew, and every formula, cask, and App Store app
# listed below.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

FORMULAE=(
    # Core
    git
    vim
    zsh
    starship

    # Terminal multiplexer
    tmux

    # Search and navigation
    fzf
    ripgrep
    fd
    broot
    zoxide

    # Git tools
    gh
    git-delta
    lazygit
    difftastic
    git-absorb

    # File viewing
    bat
    bat-extras
    glow

    # System monitoring
    htop
    bottom
    mactop
    macmon

    # Disk and process tools
    dust
    duf
    procs

    # Modern replacements
    eza
    sd
    doggo

    # Data processing
    jq
    yq

    # Networking
    httpie

    # Development utilities
    shellcheck
    tokei
    hyperfine
    watchexec
    grex
    just
    atuin
    tlrc
    lazydocker
    terminal-notifier

    # Encryption
    age
    gnupg

    # Version management and package managers
    mise
    uv
    pnpm
    oven-sh/bun/bun

    # Mac App Store CLI
    mas

    # Zsh plugins
    zsh-syntax-highlighting
    zsh-autosuggestions
)

CASKS=(
    font-monaspace
    ghostty
    zed
    google-chrome
    orbstack
    raycast
    rectangle
    stats
    appcleaner
    the-unarchiver
    logi-options+
)

# App Store ID:name. mas can only install apps your Apple Account already has, so sign in to
# the App Store and get each app there once.
MAS_APPS=(
    "937984704:Amphetamine"
    "1470584107:Dato"
)

install_command_line_tools() {
    if xcode-select -p &>/dev/null; then
        echo "Xcode Command Line Tools already installed."
        return 0
    fi
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install || true
    echo "Finish the Command Line Tools install in the dialog that opened, then re-run this script."
    exit 1
}

install_homebrew() {
    if command -v brew &>/dev/null; then
        echo "Homebrew already installed."
        return 0
    fi
    echo "Installing Homebrew..."
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
}

install_formulae() {
    echo "Installing brew formulae..."
    local formula
    for formula in "${FORMULAE[@]}"; do
        if brew list "${formula##*/}" &>/dev/null; then
            echo "  $formula already installed."
        else
            echo "  Installing $formula..."
            brew install "$formula"
        fi
    done
}

install_casks() {
    echo "Installing brew casks..."
    local cask
    for cask in "${CASKS[@]}"; do
        install_cask "$cask"
    done
}

install_mas_apps() {
    echo "Installing App Store apps..."
    local entry id name installed
    installed="$(mas list 2>/dev/null | awk '{print $1}')"
    for entry in "${MAS_APPS[@]}"; do
        id="${entry%%:*}"
        name="${entry#*:}"
        if grep -qx "$id" <<< "$installed"; then
            echo "  $name already installed."
        elif mas install "$id"; then
            echo "  Installed $name."
        else
            echo "  Couldn't install $name. Sign in to the App Store, get it once, and re-run."
        fi
    done
}

main() {
    install_command_line_tools
    install_homebrew
    install_formulae
    install_casks
    install_mas_apps
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
