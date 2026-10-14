#!/bin/bash
set -euo pipefail

# Set up this Mac or Ubuntu machine: run every step below in order, or only the steps named as
# arguments, e.g. `bash setup.sh git zsh`. Each step also runs on its own: <step>/install.sh,
# except manual-steps.sh. A failed step doesn't stop the rest; the run ends by listing it. Safe to
# re-run. With --status, report what each step has left to do, changing nothing.

# shellcheck source=lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Ubuntu also gets Docker, Chrome, Solaar, and the settings that keep it running around the clock.
# On the Mac, OrbStack provides Docker, and the homebrew step installs Chrome and Logi Options+.
# manual-steps prints what's left to do by hand.
MACOS_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed editorconfig macos manual-steps)
UBUNTU_STEPS=(homebrew runtimes git lazygit ssh zsh vim tmux ghostty zed editorconfig ubuntu docker
    chrome logitech manual-steps)
# shellcheck disable=SC2034 # runner_main reads it
STEPS_DIR="$DOTFILES_DIR"

usage() {
    echo "Usage: bash setup.sh [--status [--quick]] [--backup | --no-backup] [step...]"
    echo "Steps, run in this order by default: ${STEPS[*]}"
    echo "--status reports what each step has set up, changing nothing. It exits 3 for missing or"
    echo "unknown items. --quick skips its slowest checks: whether the Brewfile's"
    echo "formulae are all installed, and on Ubuntu, firmware updates and Docker's disk usage."
    echo "A config file edited since setup installed it is backed up before it's replaced: setup"
    echo "asks with a terminal, and backs it up without one. Settings merges also ask whether to"
    echo "back up an existing file. --backup or --no-backup answers every backup question yes or no."
    echo "Flags may come before or after the step names."
}

runner_main dotfiles "$@"
# The hint is for the zsh config, so skip it when the zsh step didn't run
if [ ${#RUNNER_STEPS[@]} -eq 0 ] || [[ " ${RUNNER_STEPS[*]} " == *" zsh "* ]]; then
    echo "Open a new terminal or run: source ~/.zshrc"
fi
