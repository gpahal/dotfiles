#!/bin/bash
set -euo pipefail

# Install every skill in ai_tools/skills globally, for Claude Code and Codex.

# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

install_skills() {
    echo "Installing skills..."
    if ! command -v npx &>/dev/null; then
        echo "  npx not found; skipping. Install Node.js (e.g. with mise) and re-run."
        return 0
    fi
    # The skills CLI (https://skills.sh) copies the skills into ~/.agents/skills (Codex) and
    # symlinks them into ~/.claude/skills (Claude Code). Re-run after changing a skill.
    npx -y skills@latest add "$DOTFILES_DIR/ai_tools/skills" \
        --global --agent claude-code codex --skill '*' --yes
}

main() {
    install_skills
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
