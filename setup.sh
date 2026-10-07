#!/bin/bash
set -euo pipefail

# Set up this Mac: run every step below in order, or only the steps named as arguments, e.g.
# `bash setup.sh git zsh`. Each step is <step>/install.sh, which also runs on its own.
# Idempotent: safe to re-run.

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed editorconfig macos)

step_script() {
    case "$1" in
        homebrew | runtimes | git | lazygit | ssh | zsh | vim | tmux | ghostty | zed | editorconfig | macos)
            echo "$DOTFILES_DIR/$1/install.sh"
            ;;
        *) return 1 ;;
    esac
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash setup.sh [step...]"
    echo "Steps, run in this order by default: ${STEPS[*]}"
    exit 0
fi

echo "=== dotfiles setup ==="
run_steps "$@"
echo ""
echo "=== Setup complete! ==="
echo "Open a new terminal or run: source ~/.zshrc"
