#!/bin/bash
set -euo pipefail

# The skills step's checks leave out what the skills CLI doesn't copy (metadata.json, .git,
# __pycache__, __pypackages__), and still see a real content change. test-skills.sh covers a mode
# change. A stub npx stands in for the skills CLI.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox

AGENTS_DIR="$HOME/.agents/skills"

# Found on PATH, so lib/common.sh doesn't put the real Homebrew, and its npx, first
stub brew
stub node 'echo "${NODE_VERSION:-v24.0.0}"'
# The skills CLI: add copies every skill into ~/.agents/skills and, for --agent claude-code, links
# it from ~/.claude/skills.
# remove, like the real one with --agent claude-code codex, deletes the Claude Code link, and the
# shared copy only when no other agent that reads ~/.agents/skills is installed. NPX_FAIL=1 makes
# add fail; NPX_REMOVE_FAIL=1 makes remove fail, changing nothing.
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

# Run the step, after clearing the stub log
step() {
    : > "$STUB_LOG"
    run "$BASH" "$STEP"
}

BACKUPS="$HOME/.local/state/dotfiles/skills-backup"
backups() {
    find "$BACKUPS" -maxdepth 1 -name "$1.2*" 2> /dev/null | sort
}

# The CLI leaves metadata.json, .git, __pycache__, and __pypackages__ out of its copies, so the
# step leaves them out of its checks too. A fixture copy of the repo, with only the interrogate
# skill, gets them, so the real skills stay untouched.
FIXTURE="$SANDBOX/dot files"
mkdir -p "$FIXTURE/ai_tools"
cp -R "$REPO_DIR/lib" "$FIXTURE/lib"
mkdir -p "$FIXTURE/ai_tools/skills/engineering"
cp -R "$REPO_DIR/ai_tools/skills/install.sh" "$REPO_DIR/ai_tools/skills/lib" "$FIXTURE/ai_tools/skills/"
cp -R "$REPO_DIR/ai_tools/skills/engineering/interrogate" "$FIXTURE/ai_tools/skills/engineering/"
STEP="$FIXTURE/ai_tools/skills/install.sh"
SRC="$FIXTURE/ai_tools/skills/engineering/interrogate"
step
assert_eq 0 "$RUN_STATUS" "the fixture's first run"
# Each left-out entry in the source, at the top and at depth, with an executable file inside
entries="metadata.json scripts/metadata.json .git scripts/__pycache__ __pycache__ __pypackages__"
for entry in $entries; do
    case "$entry" in
        *metadata.json) echo '{}' > "$SRC/$entry"; chmod +x "$SRC/$entry" ;;
        *) mkdir -p "$SRC/$entry" && echo x > "$SRC/$entry/run.sh" && chmod +x "$SRC/$entry/run.sh" ;;
    esac
done
assert_exit 0 "$BASH" "$STEP" --status
assert_not_contains "$RUN_OUTPUT" "interrogate skill" "status with left-out entries in the source"
for entry in $entries; do
    rm -rf "${SRC:?}/$entry"
done
# A cache a skill's script wrote into the installed copy isn't an edit
mkdir -p "$AGENTS_DIR/interrogate/scripts/__pycache__"
echo x > "$AGENTS_DIR/interrogate/scripts/__pycache__/run.pyc"
assert_exit 0 "$BASH" "$STEP" --status
# A real difference still counts, and the add's check passes with left-out entries in the source
mkdir -p "$SRC/__pycache__"
echo x > "$SRC/__pycache__/run.pyc"
echo '{}' > "$SRC/metadata.json"
echo "drift" >> "$SRC/SKILL.md"
assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "interrogate skill"
rm -rf "$BACKUPS"
step
assert_eq 0 "$RUN_STATUS" "status after adding a skill whose source has left-out entries"
assert_not_contains "$RUN_OUTPUT" "wasn't installed correctly"
assert_eq "" "$(backups interrogate)" "backups of a copy whose only extra is a cache"
assert_file_contains "$AGENTS_DIR/interrogate/SKILL.md" "drift"
[ ! -e "$AGENTS_DIR/interrogate/metadata.json" ] || fail "the stub copied metadata.json"
assert_exit 0 "$BASH" "$STEP" --status
# Any other untracked file is part of the skill, and gets installed
echo "notes" > "$SRC/notes.md"
assert_exit 3 "$BASH" "$STEP" --status
step
assert_file_contains "$AGENTS_DIR/interrogate/notes.md" "notes"
assert_exit 0 "$BASH" "$STEP" --status
test_done
