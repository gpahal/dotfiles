#!/bin/bash
set -euo pipefail

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

before="$(/bin/ls -i "$AGENTS_DIR/tdd/SKILL.md")"
step
assert_eq 0 "$RUN_STATUS" "re-run's status"
assert_contains "$RUN_OUTPUT" "Every skill is already installed and up to date."
assert_eq "$before" "$(/bin/ls -i "$AGENTS_DIR/tdd/SKILL.md")" "tdd's copy after a re-run"

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

# A Python cache or .git isn't a difference, in the copy or the repo
mkdir -p "$AGENTS_DIR/interrogate/scripts/__pycache__" "$SRC/engineering/interrogate/.git" "$AGENTS_DIR/tdd/.git"
touch "$AGENTS_DIR/interrogate/scripts/__pycache__/x.pyc" "$SRC/engineering/interrogate/.git/HEAD"
touch "$AGENTS_DIR/tdd/.git/HEAD"
step_status
assert_eq 0 "$RUN_STATUS" "status with caches"
step
assert_contains "$RUN_OUTPUT" "already installed and up to date"
rm -rf "$SRC/engineering/interrogate/.git"

# A missing link, a link elsewhere, or a real dir in its place is replaced by the link
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

# Entries that aren't repo skills: elsewhere, removed from the repo, dangling, stray
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

# Claude Code's own synced and dot-entries aren't extra
mkdir -p "$CLAUDE_DIR/synced/x" "$CLAUDE_DIR/.trash/y"
step_status
assert_eq 0 "$RUN_STATUS" "status with Claude Code's own entries"
assert_not_contains "$RUN_OUTPUT" "synced"
assert_not_contains "$RUN_OUTPUT" ".trash"
step
assert_eq 0 "$RUN_STATUS" "a run with Claude Code's own entries"
[ -d "$CLAUDE_DIR/synced/x" ] && [ -d "$CLAUDE_DIR/.trash/y" ] || fail "the step removed Claude Code's own entries"
rm -rf "$CLAUDE_DIR/synced" "$CLAUDE_DIR/.trash"

# Dirs that are one, through a symlink either way or nesting, fail before any change
mv "$CLAUDE_DIR" "$SANDBOX/claude-skills"
for target in "$AGENTS_DIR" "$AGENTS_DIR/tdd"; do
    ln -s "$target" "$CLAUDE_DIR"
    before="$(cd "$AGENTS_DIR" && /bin/ls -lAR)"
    step
    assert_eq 1 "$RUN_STATUS" "a run with ~/.claude/skills linked to $target"
    assert_contains "$RUN_OUTPUT" "are one dir, or one is inside the other"
    assert_eq "$before" "$(cd "$AGENTS_DIR" && /bin/ls -lAR)" "the Codex skills dir after a run with shared dirs"
    step_status
    assert_eq 3 "$RUN_STATUS" "status with ~/.claude/skills linked to $target"
    assert_contains "$RUN_OUTPUT" "missing    Skills dirs: ~/.agents/skills and ~/.claude/skills are one dir"
    assert_not_contains "$RUN_OUTPUT" "ok "
    rm "$CLAUDE_DIR"
done
mv "$AGENTS_DIR" "$SANDBOX/agents-skills"
mv "$SANDBOX/claude-skills" "$CLAUDE_DIR"
ln -s "$CLAUDE_DIR" "$AGENTS_DIR"
step
assert_eq 1 "$RUN_STATUS" "a run with ~/.agents/skills linked to ~/.claude/skills"
assert_contains "$RUN_OUTPUT" "are one dir, or one is inside the other"
rm "$AGENTS_DIR"
mv "$SANDBOX/agents-skills" "$AGENTS_DIR"
step_status
assert_eq 0 "$RUN_STATUS" "status with separate dirs again"

# A skills dir linked elsewhere, such as the repo's skills, keeps that dir's files
mv "$CLAUDE_DIR" "$SANDBOX/claude-skills"
mkdir -p "$SANDBOX/elsewhere"
touch "$SANDBOX/elsewhere/keep"
ln -s "$SANDBOX/elsewhere" "$CLAUDE_DIR"
step
assert_eq 1 "$RUN_STATUS" "a run with ~/.claude/skills linked elsewhere"
assert_contains "$RUN_OUTPUT" "skills is a symlink, so left the skills dirs alone"
[ "$(/bin/ls -A "$SANDBOX/elsewhere")" == keep ] || fail "the step changed the linked dir: $(/bin/ls -A "$SANDBOX/elsewhere")"
step_status
assert_eq 3 "$RUN_STATUS" "status with ~/.claude/skills linked elsewhere"
assert_contains "$RUN_OUTPUT" "skills is a symlink, and the step removes what it didn't install there"
rm "$CLAUDE_DIR"
mv "$SANDBOX/claude-skills" "$CLAUDE_DIR"

# With CLAUDE_CONFIG_DIR elsewhere, ~/.claude/skills is left alone
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

# Otherwise each run would install one over the other
mkdir -p "$SRC/productivity/zz-grill"
printf -- '---\nname: grill\n---\ncopy\n' > "$SRC/productivity/zz-grill/SKILL.md"
step
assert_eq 1 "$RUN_STATUS" "status with two skills named grill"
assert_contains "$RUN_OUTPUT" "ai_tools/skills/productivity/zz-grill/SKILL.md names the skill 'grill', as ai_tools/skills/productivity/grill/SKILL.md does; skipping it."
assert_file_not_contains "$AGENTS_DIR/grill/SKILL.md" "copy"
step_status
assert_contains "$RUN_OUTPUT" "Skill names in ai_tools/skills"
rm -rf "$SRC/productivity/zz-grill"

# Without any repo skill every entry would count as extra
mv "$SRC" "$SANDBOX/skills"
mkdir -p "$SRC"
cp "$SANDBOX/skills/install.sh" "$SRC/"
step
assert_eq 1 "$RUN_STATUS" "status without repo skills"
assert_contains "$RUN_OUTPUT" "Found no skills in ai_tools/skills"
[ -f "$AGENTS_DIR/tdd/SKILL.md" ] || fail "the step removed skills when the repo had none"
step_status
assert_eq 3 "$RUN_STATUS" "status without repo skills"
assert_contains "$RUN_OUTPUT" "missing    Skills in ai_tools/skills: found none"
assert_not_contains "$RUN_OUTPUT" "ok "
assert_not_contains "$RUN_OUTPUT" "which isn't a skill"
test_done
