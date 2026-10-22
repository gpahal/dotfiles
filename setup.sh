#!/bin/bash
set -euo pipefail

# Set up this Mac or Ubuntu machine: run every step below in order, or only the steps named.

# shellcheck source=lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# On the Mac, OrbStack provides Docker, and the homebrew step installs Chrome and Logi Options+
MACOS_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed stream-deck hammerspoon vicinae
    editorconfig macos manual-steps)
UBUNTU_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed stream-deck hotkeys gnome vicinae
    editorconfig ubuntu docker chrome logitech monitor-input manual-steps)
# shellcheck disable=SC2034 # runner_main reads it
STEPS_DIR="$DOTFILES_DIR"

runner_main dotfiles "--quick skips its slowest checks: whether the Brewfile's
formulae are all installed, and on Ubuntu, firmware updates and Docker's disk usage." "$@"
if [ ${#RUNNER_STEPS[@]} -eq 0 ] || [[ " ${RUNNER_STEPS[*]} " == *" zsh "* ]]; then
    # Not source ~/.zshrc: setup runs from bash on a fresh Ubuntu, and bash can't read zsh's config
    echo "Open a new terminal or run: exec zsh -l"
fi
