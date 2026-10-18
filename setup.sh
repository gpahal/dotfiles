#!/bin/bash
set -euo pipefail

# Set up this Mac or Ubuntu machine: run every step below in order, or only the steps named as
# arguments, e.g. `bash setup.sh git zsh`. Each step also runs on its own: <step>/install.sh,
# except manual-steps.sh. A failed step doesn't stop the rest; the run ends by listing it. Safe to
# re-run. With --status, report what each step has left to do, changing nothing.

# shellcheck source=lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Ubuntu also gets Docker, Chrome, Solaar, and the settings that keep it running around the clock.
# The Mac gets Stream Deck, Hammerspoon, and the macos step's defaults instead. On the Mac, OrbStack
# provides Docker, and the homebrew step installs Chrome and Logi Options+.
# manual-steps prints what's left to do by hand.
MACOS_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed stream-deck hammerspoon editorconfig
    macos manual-steps)
UBUNTU_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed editorconfig ubuntu docker
    chrome logitech manual-steps)
# shellcheck disable=SC2034 # runner_main reads it
STEPS_DIR="$DOTFILES_DIR"

runner_main dotfiles "--quick skips its slowest checks: whether the Brewfile's
formulae are all installed, and on Ubuntu, firmware updates and Docker's disk usage." "$@"
# The hint is for the zsh config, so skip it when the zsh step didn't run
if [ ${#RUNNER_STEPS[@]} -eq 0 ] || [[ " ${RUNNER_STEPS[*]} " == *" zsh "* ]]; then
    echo "Open a new terminal or run: source ~/.zshrc"
fi
