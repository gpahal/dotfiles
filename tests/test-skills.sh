#!/bin/bash
set -euo pipefail

# The skills step copies each repo skill into ~/.agents/skills and links it from ~/.claude/skills,
# replaces a copy that differs from the repo, down to its executable bits, and removes every entry
# that isn't a repo skill. A Python cache or .git in a copy doesn't count as a difference. A re-run
# changes nothing, and --status names what the step would change. It runs on a copy of the repo
# with three skills.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox

AGENTS_DIR="$HOME/.agents/skills"
CLAUDE_DIR="$HOME/.claude/skills"
FIXTURE="$SANDBOX/dot files"
mkdir -p "$FIXTURE/ai_tools/skills"
cp -R "$REPO_DIR/lib" "$FIXTURE/lib"
cp "$REPO_DIR/ai_tools/skills/install.sh" "$FIXTURE/ai_tools/skills/"
for skill in engineering/tdd engineering/interrogate productivity/grill; do
    mkdir -p "$FIXTURE/ai_tools/skills/$(dirname "$skill")"
    cp -R "$REPO_DIR/ai_tools/skills/$skill" "$FIXTURE/ai_tools/skills/$skill"
done
STEP="$FIXTURE/ai_tools/skills/install.sh"
SRC="$FIXTURE/ai_tools/skills"

step() {
    run "$BASH" "$STEP"
}

step_status() {
    run "$BASH" "$STEP" --status
}

# A first run copies and links every skill
step
assert_eq 0 "$RUN_STATUS" "first run's status"
for name in tdd interrogate grill; do
    [ -f "$AGENTS_DIR/$name/SKILL.md" ] || fail "the first run didn't copy $name"
    assert_eq "$AGENTS_DIR/$name" "$(readlink "$CLAUDE_DIR/$name")" "the link to $name"
done
assert_contains "$RUN_OUTPUT" "Copied the tdd skill to ~/.agents/skills/tdd"
assert_contains "$RUN_OUTPUT" "Linked ~/.claude/skills/tdd to the tdd skill"
[ -x "$AGENTS_DIR/interrogate/scripts/run-reviewer.sh" ] || fail "run-reviewer.sh isn't executable"
step_status
assert_eq 0 "$RUN_STATUS" "status after the first run"
assert_contains "$RUN_OUTPUT" "ok         Every skill in ai_tools/skills, installed and up to date"

# A re-run changes nothing
before="$(/bin/ls -i "$AGENTS_DIR/tdd/SKILL.md")"
step
assert_eq 0 "$RUN_STATUS" "re-run's status"
assert_contains "$RUN_OUTPUT" "Every skill is already installed and up to date."
assert_eq "$before" "$(/bin/ls -i "$AGENTS_DIR/tdd/SKILL.md")" "tdd's copy after a re-run"

# A copy edited by hand differs, and is replaced. So is a copy with a file the repo lacks, and one
# that lost an executable bit.
echo "drift" >> "$AGENTS_DIR/tdd/SKILL.md"
touch "$AGENTS_DIR/grill/notes.md"
chmod -x "$AGENTS_DIR/interrogate/scripts/run-reviewer.sh"
step_status
assert_eq 3 "$RUN_STATUS" "status with edited copies"
for name in tdd grill interrogate; do
    assert_contains "$RUN_OUTPUT" "missing    $name skill, differs from the repo"
done
step
assert_eq 0 "$RUN_STATUS" "status after replacing edited copies"
assert_file_not_contains "$AGENTS_DIR/tdd/SKILL.md" "drift"
[ ! -e "$AGENTS_DIR/grill/notes.md" ] || fail "the extra file in grill's copy is still there"
[ -x "$AGENTS_DIR/interrogate/scripts/run-reviewer.sh" ] || fail "the exec bit wasn't restored"
assert_not_contains "$RUN_OUTPUT" "Linked"

# A Python cache a skill's script writes, and a .git, aren't differences, in the copy or the repo
mkdir -p "$AGENTS_DIR/interrogate/scripts/__pycache__" "$SRC/engineering/interrogate/.git" "$AGENTS_DIR/tdd/.git"
touch "$AGENTS_DIR/interrogate/scripts/__pycache__/x.pyc" "$SRC/engineering/interrogate/.git/HEAD"
touch "$AGENTS_DIR/tdd/.git/HEAD"
step_status
assert_eq 0 "$RUN_STATUS" "status with caches"
step
assert_contains "$RUN_OUTPUT" "already installed and up to date"
rm -rf "$SRC/engineering/interrogate/.git"

# A missing copy is not installed. A missing link, a link elsewhere, and a real directory where the
# link goes are each replaced by the link.
rm -rf "$AGENTS_DIR/grill"
rm "$CLAUDE_DIR/tdd"
ln -sfn "$SANDBOX" "$CLAUDE_DIR/interrogate"
step_status
assert_contains "$RUN_OUTPUT" "missing    grill skill, not installed"
assert_contains "$RUN_OUTPUT" "missing    tdd skill, not linked from ~/.claude/skills"
assert_contains "$RUN_OUTPUT" "missing    interrogate skill, not linked from ~/.claude/skills"
step
rm "$CLAUDE_DIR/tdd"
mkdir "$CLAUDE_DIR/tdd"
touch "$CLAUDE_DIR/tdd/SKILL.md"
step
assert_eq 0 "$RUN_STATUS" "status after fixing the links"
for name in tdd interrogate grill; do
    assert_eq "$AGENTS_DIR/$name" "$(readlink "$CLAUDE_DIR/$name")" "the link to $name after a fix"
done
[ ! -e "$AGENTS_DIR/tdd/tdd" ] || fail "the link went inside a directory"

# An entry that isn't a repo skill, in either dir, is reported, then removed: a skill from
# elsewhere, one the repo no longer has, its dangling link, and a stray file
mkdir -p "$AGENTS_DIR/old-skill"
printf -- '---\nname: old-skill\n---\n' > "$AGENTS_DIR/old-skill/SKILL.md"
ln -s "$AGENTS_DIR/old-skill" "$CLAUDE_DIR/old-skill"
ln -s "$AGENTS_DIR/gone" "$CLAUDE_DIR/gone"
touch "$AGENTS_DIR/.DS_Store"
step_status
assert_eq 3 "$RUN_STATUS" "status with extra entries"
assert_contains "$RUN_OUTPUT" "missing    ~/.agents/skills/old-skill, which isn't a skill in ai_tools/skills; the step removes it"
assert_contains "$RUN_OUTPUT" "missing    ~/.claude/skills/gone, which isn't a skill in ai_tools/skills"
assert_contains "$RUN_OUTPUT" "missing    ~/.agents/skills/.DS_Store"
step
assert_eq 0 "$RUN_STATUS" "status after removing extra entries"
assert_contains "$RUN_OUTPUT" "Removed ~/.agents/skills/old-skill, which isn't a skill in ai_tools/skills"
for path in "$AGENTS_DIR/old-skill" "$CLAUDE_DIR/old-skill" "$CLAUDE_DIR/gone" "$AGENTS_DIR/.DS_Store"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$path is still there"
done
[ -f "$AGENTS_DIR/tdd/SKILL.md" ] || fail "a repo skill was removed with the extra entries"
step_status
assert_eq 0 "$RUN_STATUS" "status after removing extra entries"

# CLAUDE_CONFIG_DIR elsewhere: the skills are for Codex only, and ~/.claude/skills, extra entries
# included, is left alone
rm -rf "$AGENTS_DIR" "$CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/mine"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude-config"
step
assert_eq 0 "$RUN_STATUS" "status with CLAUDE_CONFIG_DIR set"
assert_contains "$RUN_OUTPUT" "so the skills are for Codex only"
[ -f "$AGENTS_DIR/tdd/SKILL.md" ] || fail "tdd wasn't installed for Codex"
assert_eq "mine" "$(/bin/ls -A "$CLAUDE_DIR")" "Claude Code's skills dir with CLAUDE_CONFIG_DIR set"
step_status
assert_eq 0 "$RUN_STATUS" "status with CLAUDE_CONFIG_DIR set"
assert_contains "$RUN_OUTPUT" "skipped    Skills for Claude Code: CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR"
unset CLAUDE_CONFIG_DIR
rm -rf "$CLAUDE_DIR/mine"
step

# A repo skill whose name isn't one is skipped, failing the step, and the rest are still installed
mkdir -p "$SRC/productivity/bad"
printf -- '---\nname: ../bad\n---\n' > "$SRC/productivity/bad/SKILL.md"
echo "drift" >> "$AGENTS_DIR/grill/SKILL.md"
step
assert_eq 1 "$RUN_STATUS" "status with a bad skill name"
assert_contains "$RUN_OUTPUT" "names its skill '../bad'"
assert_file_not_contains "$AGENTS_DIR/grill/SKILL.md" "drift"
[ ! -e "$HOME/.agents/bad" ] || fail "a bad skill name escaped the skills dir"
step_status
assert_eq 3 "$RUN_STATUS" "status with a bad skill name"
assert_contains "$RUN_OUTPUT" "one isn't lowercase letters, digits, and dashes"
rm -rf "$SRC/productivity/bad"

# Two skills with one name fail the step, naming both files, and only the first, by path, is
# installed. Otherwise each run would install one over the other.
mkdir -p "$SRC/productivity/zz-grill"
printf -- '---\nname: grill\n---\ncopy\n' > "$SRC/productivity/zz-grill/SKILL.md"
step
assert_eq 1 "$RUN_STATUS" "status with two skills named grill"
assert_contains "$RUN_OUTPUT" "ai_tools/skills/productivity/zz-grill/SKILL.md names the skill 'grill', as ai_tools/skills/productivity/grill/SKILL.md does; skipping it."
assert_file_not_contains "$AGENTS_DIR/grill/SKILL.md" "copy"
step_status
assert_contains "$RUN_OUTPUT" "Skill names in ai_tools/skills"
rm -rf "$SRC/productivity/zz-grill"

# Without any repo skill, every entry would count as extra, so the step fails and removes nothing
mv "$SRC" "$SANDBOX/skills"
mkdir -p "$SRC"
cp "$SANDBOX/skills/install.sh" "$SRC/"
step
assert_eq 1 "$RUN_STATUS" "status without repo skills"
assert_contains "$RUN_OUTPUT" "Found no skills in ai_tools/skills"
[ -f "$AGENTS_DIR/tdd/SKILL.md" ] || fail "the step removed skills when the repo had none"
test_done
