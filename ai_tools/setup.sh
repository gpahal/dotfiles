#!/bin/bash
set -euo pipefail

# Set up AI tools: run every step below in order, or only the steps named as arguments, e.g.
# `bash ai_tools/setup.sh codex`. Each step's script also runs on its own.
#
# - claude-code: Claude Code CLI, its settings, and the user-level instructions
# - claude-desktop: Claude desktop app
# - codex: Codex CLI and ChatGPT desktop app, their shared config, and the user-level instructions
# - t3-code: T3 Code desktop app
# - skills: the skills in ai_tools/skills, for Claude Code and Codex
# - manual-steps: what macOS doesn't let scripts change (notification alert style, browser
#   extensions), opened for you
#
# Idempotent: safe to re-run. Apps whose config is edited (Claude, ChatGPT, T3 Code) must be
# quit first; when run interactively the script offers to quit them, otherwise it skips them.
# See ai_tools/README.md for the full checklist.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

STEPS=(claude-code claude-desktop codex t3-code skills manual-steps)

step_script() {
    case "$1" in
        claude-code | claude-desktop | codex | t3-code | skills)
            echo "$DOTFILES_DIR/ai_tools/$1/install.sh"
            ;;
        manual-steps) echo "$DOTFILES_DIR/ai_tools/manual-steps.sh" ;;
        *) return 1 ;;
    esac
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash ai_tools/setup.sh [step...]"
    echo "Steps, run in this order by default: ${STEPS[*]}"
    exit 0
fi

echo "=== AI tools setup ==="
run_steps "$@"
echo ""
echo "=== AI tools setup complete! ==="
