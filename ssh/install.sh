#!/bin/bash
set -euo pipefail

# Add the github.com block from ssh/config to ~/.ssh/config, unless it already has a
# `Host github.com` block. Other tools (e.g. OrbStack) add their own lines to that file, so
# it's never replaced.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

SSH_CONFIG="$HOME/.ssh/config"

main() {
    echo "Configuring SSH..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    if [ -f "$SSH_CONFIG" ] && grep -qiE '^[[:space:]]*Host[[:space:]]+github\.com[[:space:]]*$' "$SSH_CONFIG"; then
        echo "  $SSH_CONFIG already has a github.com block"
        return 0
    fi
    # Keep a blank line between existing content and the new block
    if [ -s "$SSH_CONFIG" ]; then
        echo "" >> "$SSH_CONFIG"
    fi
    cat "$DOTFILES_DIR/ssh/config" >> "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
    echo "  Added the github.com block to $SSH_CONFIG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
