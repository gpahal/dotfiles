#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== dotfiles setup ==="

# ─── Install Homebrew ───
if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    echo "Homebrew already installed."
fi

# ─── Install brew formulae ───
echo "Installing brew formulae..."
FORMULAE=(
    # Core
    git
    vim
    zsh
    starship

    # Search and navigation
    fzf
    ripgrep
    fd
    broot
    zoxide

    # Git tools
    delta
    lazygit

    # File viewing
    bat
    bat-extras
    glow

    # System monitoring
    htop
    bottom

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
    tokei
    hyperfine
    watchexec
    difftastic
    grex
    just

    # Help and docs
    tlrc

    # Shell history
    atuin

    # Version management
    mise

    # Zsh plugins
    zsh-syntax-highlighting
    zsh-autosuggestions
)

for formula in "${FORMULAE[@]}"; do
    if brew list "$formula" &>/dev/null; then
        echo "  $formula already installed."
    else
        echo "  Installing $formula..."
        brew install "$formula"
    fi
done

# ─── Install brew casks ───
echo "Installing brew casks..."
CASKS=(
    font-monaspace
    ghostty
    zed
    raycast
    rectangle
    appcleaner
    the-unarchiver
)

for cask in "${CASKS[@]}"; do
    if brew list --cask "$cask" &>/dev/null; then
        echo "  $cask already installed."
    else
        echo "  Installing $cask..."
        brew install --cask "$cask"
    fi
done

# ─── Copy git config ───
echo "Copying git config..."
cp "$DOTFILES_DIR/git/gitconfig" "$HOME/.gitconfig"

# ─── Copy vim config ───
echo "Copying vim config..."
cp "$DOTFILES_DIR/vim/vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.vim/undodir"

# ─── Copy zsh files ───
echo "Copying zsh files..."
rm -rf "$HOME/.zsh"
mkdir -p "$HOME/.zsh"
cp "$DOTFILES_DIR"/zsh/*.zsh "$HOME/.zsh/"

echo "Copying starship config..."
mkdir -p "$HOME/.config"
cp -r "$DOTFILES_DIR"/zsh/config/* "$HOME/.config/"

# ─── Set up .zshrc ───
ZSHRC_LINE='source $HOME/.zsh/main.zsh'
if [ -f "$HOME/.zshrc" ]; then
    if ! grep -qF "$ZSHRC_LINE" "$HOME/.zshrc"; then
        echo "Adding source line to .zshrc..."
        echo "$ZSHRC_LINE" >> "$HOME/.zshrc"
    else
        echo ".zshrc already sources main.zsh."
    fi
else
    echo "Creating .zshrc..."
    echo "$ZSHRC_LINE" > "$HOME/.zshrc"
fi

# ─── Copy Ghostty config ───
echo "Copying Ghostty config..."
rm -rf "$HOME/.config/ghostty"
mkdir -p "$HOME/.config/ghostty"
cp "$DOTFILES_DIR/ghostty/config" "$HOME/.config/ghostty/config"

# ─── Set zsh as login shell ───
CURRENT_SHELL="$(basename "$SHELL")"
if [ "$CURRENT_SHELL" != "zsh" ]; then
    ZSH_PATH="$(which zsh)"
    echo "Setting zsh as login shell (may require password)..."
    if ! grep -qF "$ZSH_PATH" /etc/shells; then
        echo "Adding $ZSH_PATH to /etc/shells..."
        echo "$ZSH_PATH" | sudo tee -a /etc/shells || echo "  Failed — run manually: echo '$ZSH_PATH' | sudo tee -a /etc/shells"
    fi
    chsh -s "$ZSH_PATH" || echo "  Failed — run manually: chsh -s $ZSH_PATH"
else
    echo "zsh is already the login shell."
fi

# ─── macOS defaults ───
if [[ "$(uname)" == "Darwin" ]]; then
    echo "Setting macOS defaults..."

    # Finder: show hidden files
    defaults write com.apple.finder AppleShowAllFiles -bool true

    # Finder: show all file extensions
    defaults write NSGlobalDomain AppleShowAllExtensions -bool true

    # Finder: show path bar and status bar
    defaults write com.apple.finder ShowPathbar -bool true
    defaults write com.apple.finder ShowStatusBar -bool true

    # Finder: default to list view
    defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

    # Finder: keep folders on top when sorting
    defaults write com.apple.finder _FXSortFoldersFirst -bool true

    # Finder: disable warning when changing file extension
    defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

    # Finder: search current folder by default
    defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

    # Fast key repeat rate (essential for vim)
    defaults write NSGlobalDomain KeyRepeat -int 2
    defaults write NSGlobalDomain InitialKeyRepeat -int 15

    # Disable press-and-hold for accent characters (enables key repeat)
    defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false

    # Dock: auto-hide with no delay
    defaults write com.apple.dock autohide -bool true
    defaults write com.apple.dock autohide-delay -float 0
    defaults write com.apple.dock autohide-time-modifier -float 0.4

    # Dock: minimize to application icon
    defaults write com.apple.dock minimize-to-application -bool true

    # Dock: don't show recent apps
    defaults write com.apple.dock show-recents -bool false

    # Screenshots: save to ~/Screenshots as PNG
    mkdir -p "$HOME/Screenshots"
    defaults write com.apple.screencapture location -string "$HOME/Screenshots"
    defaults write com.apple.screencapture type -string "png"

    # Disable smart quotes and dashes (break code in terminals)
    defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
    defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false

    # TextEdit: use plain text by default
    defaults write com.apple.TextEdit RichText -int 0

    # Activity Monitor: show all processes
    defaults write com.apple.ActivityMonitor ShowCategory -int 0

    # Restart affected apps
    killall Finder Dock 2>/dev/null || true

    echo "macOS defaults set."
fi

# ─── Reload Ghostty config ───
if pgrep -x ghostty &>/dev/null; then
    echo "Reloading Ghostty config..."
    killall -SIGUSR1 ghostty
else
    echo "Ghostty is not running; skipping reload."
fi

echo ""
echo "=== Setup complete! ==="
echo "Open a new terminal or run: source ~/.zshrc"
