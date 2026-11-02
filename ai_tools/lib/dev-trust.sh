# shellcheck shell=bash

# The folders the claude-code and codex steps trust, so neither asks: ~/Dev and each git repo in
# it, as ~/Dev/<repo> or ~/Dev/<group>/<repo>. Both tools look up trust at the working directory
# and the repo root only, never in a folder above the repo, so each repo gets its own entry. A repo
# cloned later is trusted when the steps re-run; until then their --status reports it missing.

DEV_TRUST_DIR="$HOME/Dev"

# Prints each folder, one per line, ~/Dev first, with symlinks resolved, as both tools key trust by
# the resolved path. Prints nothing when ~/Dev doesn't exist.
dev_trust_dirs() {
    local dev git
    dev="$(cd -P "$DEV_TRUST_DIR" 2>/dev/null && pwd)" || return 0
    printf '%s\n' "$dev"
    # A worktree's .git is a file, so -name rather than -type d
    find "$dev" -mindepth 2 -maxdepth 3 -name .git 2>/dev/null | LC_ALL=C sort |
        while IFS= read -r git; do
            printf '%s\n' "${git%/.git}"
        done
}
