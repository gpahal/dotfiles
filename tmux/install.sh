#!/bin/bash
set -euo pipefail

# Copy the tmux config and tmux-sessionizer, and install tpm and the plugins tmux.conf lists into ~/.tmux/plugins.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PLUGIN_DIR="$HOME/.tmux/plugins"

main() {
    local plugin missing=false
    echo "Copying tmux config..."
    copy_file "$DOTFILES_DIR/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"
    copy_file "$DOTFILES_DIR/tmux/bin/tmux-sessionizer" "$HOME/.local/bin/tmux-sessionizer"
    chmod 755 "$HOME/.local/bin/tmux-sessionizer"

    if [ -d "$PLUGIN_DIR/tpm" ]; then
        echo "tpm already installed."
    else
        echo "Installing tmux plugin manager (tpm)..."
        git clone https://github.com/tmux-plugins/tpm "$PLUGIN_DIR/tpm"
    fi

    while IFS= read -r plugin; do
        [ -d "$PLUGIN_DIR/${plugin##*/}" ] || missing=true
    done < <(sed -n "s/^set -g @plugin '\(.*\)'/\1/p" "$DOTFILES_DIR/tmux/tmux.conf")
    if "$missing"; then
        echo "Installing tmux plugins..."
        "$PLUGIN_DIR/tpm/bin/install_plugins"
    else
        echo "tmux plugins already installed."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
