#!/bin/bash
set -euo pipefail

# Set up AI tools: run every step in order, or only the steps named as arguments.
# t3-code runs after codex so its service starts with the Codex CLI installed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

MACOS_STEPS=(claude-code claude-desktop codex t3-code skills manual-steps)
UBUNTU_STEPS=("${MACOS_STEPS[@]}")
# shellcheck disable=SC2034 # runner_main reads it
STEPS_DIR="$DOTFILES_DIR/ai_tools"

runner_main "AI tools" "--quick skips its slowest checks: on Ubuntu, whether the
T3 Code service stays up, and T3 Code's browser setup." "$@"
