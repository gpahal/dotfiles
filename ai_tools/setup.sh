#!/bin/bash
set -euo pipefail

# Set up AI tools: run every step in MACOS_STEPS or UBUNTU_STEPS in order, or only the steps named
# as arguments, e.g. `bash ai_tools/setup.sh codex`. Each step's script also runs on its own.
# ai_tools/README.md says what each step sets up. t3-code runs after codex, so its service starts
# with the Codex CLI already installed.
#
# A step that fails doesn't stop the rest; the run ends by listing it. Idempotent: safe to
# re-run. With --status, report what each step has left to do, changing nothing. Apps whose
# config is edited (Claude, ChatGPT, T3 Code) must be quit first; when run interactively the
# script offers to quit them, otherwise it skips their settings.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

MACOS_STEPS=(claude-code claude-desktop codex t3-code skills manual-steps)
UBUNTU_STEPS=(claude-code codex t3-code skills manual-steps)
# shellcheck disable=SC2034 # runner_main reads it
STEPS_DIR="$DOTFILES_DIR/ai_tools"

runner_main "AI tools" "--quick skips its slowest checks: on Ubuntu, whether the
T3 Code service stays up, and T3 Code's browser setup." "$@"
