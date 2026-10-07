#!/bin/bash
set -euo pipefail

# Install the zsh config and starship prompt, hook them into ~/.zshrc and ~/.zprofile, and make
# zsh the login shell.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck disable=SC2016 # lines written to files, expanded when zsh reads them
ZSHRC_LINE='source $HOME/.zsh/main.zsh'
# Homebrew and mise shims for login shells, so tools started from a login shell (editors,
# agents) find brew and mise binaries. Interactive shells switch to `mise activate` in
# zsh/plugins.zsh.
# shellcheck disable=SC2016
ZPROFILE_LINES=(
    'eval "$(/opt/homebrew/bin/brew shellenv zsh)"'
    'command -v mise &>/dev/null && eval "$(mise activate zsh --shims)"'
)

copy_files() {
    local file
    echo "Copying zsh files..."
    # Copy file by file: ~/.zsh also holds the completion cache, which a fresh copy would wipe
    for file in "$DOTFILES_DIR"/zsh/*.zsh; do
        copy_file "$file" "$HOME/.zsh/${file##*/}"
    done
    echo "Copying starship config..."
    copy_file "$DOTFILES_DIR/zsh/config/starship.toml" "$HOME/.config/starship.toml"
}

setup_zshrc() {
    if append_line "$ZSHRC_LINE" "$HOME/.zshrc"; then
        echo "  Added the main.zsh source line to ~/.zshrc"
    else
        echo "  ~/.zshrc already sources main.zsh"
    fi
}

# Add lines that are missing, keeping whatever else installers (e.g. OrbStack) put there
setup_zprofile() {
    local line added=false
    for line in "${ZPROFILE_LINES[@]}"; do
        append_line "$line" "$HOME/.zprofile" && added=true
    done
    if "$added"; then
        echo "  Added Homebrew and mise lines to ~/.zprofile"
    else
        echo "  ~/.zprofile already sets up Homebrew and mise"
    fi
}

set_login_shell() {
    local zsh_path
    if [ "$(basename "$SHELL")" == "zsh" ]; then
        echo "zsh is already the login shell."
        return 0
    fi
    zsh_path="$(command -v zsh)"
    echo "Setting zsh as login shell (may require password)..."
    if ! grep -qF "$zsh_path" /etc/shells; then
        echo "Adding $zsh_path to /etc/shells..."
        echo "$zsh_path" | sudo tee -a /etc/shells || echo "  Failed. Run manually: echo '$zsh_path' | sudo tee -a /etc/shells"
    fi
    chsh -s "$zsh_path" || echo "  Failed. Run manually: chsh -s $zsh_path"
}

main() {
    copy_files
    echo "Setting up ~/.zshrc and ~/.zprofile..."
    setup_zshrc
    setup_zprofile
    set_login_shell
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
