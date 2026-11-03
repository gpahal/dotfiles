#!/bin/bash
set -euo pipefail

# Set up this Mac or Ubuntu machine: run every step below in order, or only the steps named.
# A step is <step>/install.sh, or ai_tools/<step>/install.sh for an AI tool. A group's name runs its
# steps. t3-code runs after codex so its service starts with the Codex CLI installed.

# shellcheck source=lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/runner.sh
source "$DOTFILES_DIR/lib/runner.sh"

AI_STEPS=(claude-code claude-desktop codex t3-code skills)
# On the Mac, OrbStack provides Docker, and the homebrew step installs Chrome and Logi Options+
MACOS_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed stream-deck hammerspoon vicinae
    editorconfig macos ntfy "${AI_STEPS[@]}" manual-steps)
UBUNTU_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed stream-deck hotkeys gnome vicinae
    editorconfig ubuntu docker ntfy chrome logitech monitor-input "${AI_STEPS[@]}" manual-steps)
# shellcheck disable=SC2034 # runner_main reads it
STEP_GROUPS=("ai:${AI_STEPS[*]} manual-steps" "claude:claude-code claude-desktop")

runner_main dotfiles "checking the GitHub login and whether the Brewfile's formulae are all
installed, and on Ubuntu, firmware updates, Docker's disk usage, that the T3 Code service stays up,
and T3 Code's browser setup" "$@"
if [ ${#RUNNER_STEPS[@]} -eq 0 ] || [[ " ${RUNNER_STEPS[*]} " == *" zsh "* ]]; then
    # Not source ~/.zshrc: setup runs from bash on a fresh Ubuntu, and bash can't read zsh's config
    echo "Open a new terminal or run: exec zsh -l"
fi
