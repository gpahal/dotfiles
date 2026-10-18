# shellcheck shell=bash
# A test double of the skills CLI, and helpers, for the skills step's tests, which source this file
# after tests/lib.sh and setup_sandbox. It stubs npx, node, and brew, and defines:
# - skills_fixture <skill dir>...: a copy of the repo at $FIXTURE with only the named skills, given
#   relative to ai_tools/skills, so the step, which hashes every skill each run, stays fast and the
#   real skills stay untouched. Sets STEP to the copy's step.
# - step: run the step, after clearing the stub log.
# - backups <label>: print the backups made of a skill's copy, one per line.

# shellcheck disable=SC2034 # the tests read them
AGENTS_DIR="$HOME/.agents/skills"
# shellcheck disable=SC2034
CLAUDE_DIR="$HOME/.claude/skills"
BACKUPS="$HOME/.local/state/dotfiles/skills-backup"

# Found on PATH, so lib/common.sh doesn't put the real Homebrew, and its npx, first
stub brew
stub node 'echo "${NODE_VERSION:-v24.0.0}"'
# The skills CLI: add copies every skill into ~/.agents/skills and, for --agent claude-code, links
# it from ~/.claude/skills.
# remove, like the real one with --agent claude-code codex, deletes the Claude Code link, and the
# shared copy only when no other agent that reads ~/.agents/skills is installed. NPX_FAIL=1 makes
# add fail; NPX_REMOVE_FAIL=1 makes remove fail, changing nothing. NPX_SKIP=<name> makes add skip
# that skill but exit zero.
stub npx '
case "$3" in
    add)
        [ "${NPX_FAIL:-}" != 1 ] || exit 1
        # The names after --skill, or * for every skill
        only=" $(printf "%s\n" "$@" | sed -n "/^--skill$/,/^--/p" | sed "/^--/d" | tr "\n" " ")"
        claude=false
        [[ " $* " != *" claude-code "* ]] || { claude=true; mkdir -p "$HOME/.claude/skills"; }
        mkdir -p "$HOME/.agents/skills"
        find "$4" -name SKILL.md | while IFS= read -r f; do
            d="$(dirname "$f")"
            n="$(basename "$d")"
            [ "$only" = " * " ] || [[ "$only" == *" $n "* ]] || continue
            [ "$n" != "${NPX_SKIP:-}" ] || continue
            rm -rf "$HOME/.agents/skills/$n"
            cp -Rp "$d" "$HOME/.agents/skills/$n"
            # What skills@1.7.1 leaves out of the copy
            find "$HOME/.agents/skills/$n" \( -name metadata.json -o -type d \( -name .git -o -name __pycache__ -o -name __pypackages__ \) \) \
                -prune -exec rm -rf {} +
            "$claude" || continue
            rm -rf "$HOME/.claude/skills/$n"
            ln -s "$HOME/.agents/skills/$n" "$HOME/.claude/skills/$n"
        done
        ;;
    remove)
        [ "${NPX_REMOVE_FAIL:-}" != 1 ] || exit 1
        for n; do :; done
        rm -rf "$HOME/.claude/skills/$n"
        [ -d "$HOME/.config/zed" ] || [ -d "$HOME/.cursor" ] || rm -rf "$HOME/.agents/skills/$n"
        ;;
esac'

skills_fixture() {
    local skill
    FIXTURE="$SANDBOX/dot files"
    mkdir -p "$FIXTURE/ai_tools/skills"
    cp -R "$REPO_DIR/lib" "$FIXTURE/lib"
    cp -R "$REPO_DIR/ai_tools/skills/install.sh" "$REPO_DIR/ai_tools/skills/lib" "$FIXTURE/ai_tools/skills/"
    for skill; do
        mkdir -p "$FIXTURE/ai_tools/skills/$(dirname "$skill")"
        cp -R "$REPO_DIR/ai_tools/skills/$skill" "$FIXTURE/ai_tools/skills/$skill"
    done
    STEP="$FIXTURE/ai_tools/skills/install.sh"
}

step() {
    : > "$STUB_LOG"
    run "$BASH" "$STEP"
}

backups() {
    find "$BACKUPS" -maxdepth 1 -name "$1.2*" 2> /dev/null | sort
}
