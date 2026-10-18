#!/bin/bash
set -euo pipefail

# The skills step adds the skills only when an installed copy is missing or differs, backs up a
# copy edited by hand before replacing it, keeps or removes skills the repo no longer has, removes
# them even when adding fails, and names the problem skills in --status.
# tests/skills-cli-stub.sh stands in for the skills CLI. It runs the step about 40 times, so it runs on a copy of the repo with three skills.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox

# shellcheck source=skills-cli-stub.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills-cli-stub.sh"
# The step hashes every skill on each run, so a copy with only the skills the checks name keeps it fast
skills_fixture engineering/tdd engineering/interrogate productivity/grill
STATE="$HOME/.local/state/dotfiles/installed-skills"

# Succeeds when the record holds a hash for the named skill
hashed() {
    grep -qE "^[0-9a-f]{64}  $1\$" "$STATE"
}

# Install a skill by hand, as if another source had added it
fake_skill() {
    mkdir -p "$AGENTS_DIR/$1" "$CLAUDE_DIR"
    printf -- '---\nname: %s\n---\n' "$1" > "$AGENTS_DIR/$1/SKILL.md"
    ln -sfn "$AGENTS_DIR/$1" "$CLAUDE_DIR/$1"
}

# A first run adds every skill and records them
step
assert_eq 0 "$RUN_STATUS" "first run's status"
assert_file_contains "$STUB_LOG" "npx -y skills@"
[ -f "$AGENTS_DIR/tdd/SKILL.md" ] || fail "the first run didn't install tdd"
assert_file_contains "$STATE" "tdd"
assert_exit 0 "$BASH" "$STEP" --status

# An up-to-date install isn't added again
step
assert_eq 0 "$RUN_STATUS" "up-to-date run's status"
assert_contains "$RUN_OUTPUT" "already installed and up to date"
assert_file_not_contains "$STUB_LOG" " add "

# Changed content is added again, and --status names the skill
echo "drift" >> "$AGENTS_DIR/tdd/SKILL.md"
assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "tdd skill"
assert_not_contains "$RUN_OUTPUT" "grill skill"
step
# Only the skill that changed is added again
assert_file_contains "$STUB_LOG" "--skill tdd --yes"
assert_exit 0 "$BASH" "$STEP" --status

# So is a lost exec bit
chmod -x "$AGENTS_DIR/interrogate/scripts/run-reviewer.sh"
assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "interrogate skill"
step
assert_file_contains "$STUB_LOG" " add "
[ -x "$AGENTS_DIR/interrogate/scripts/run-reviewer.sh" ] || fail "the exec bit wasn't restored"

# So is a missing skill, which --status names as not installed, though Ubuntu's realpath, unlike
# macOS's, resolves a path whose last part is missing. The stub does that on macOS too.
rm -rf "$AGENTS_DIR/grill" "$CLAUDE_DIR/grill"
stub realpath '[ -e "$1" ] || [ -L "$1" ] || { printf "%s/%s\n" "$('"$(command -v realpath)"' "$(dirname "$1")")" "${1##*/}"; exit; }
exec '"$(command -v realpath)"' "$@"'
assert_exit 3 "$BASH" "$STEP" --status
rm "$STUB_DIR/realpath"
assert_contains "$RUN_OUTPUT" "grill skill, not installed"
step
assert_file_contains "$STUB_LOG" " add "

# A stale skill is kept without a terminal, and offered again next time
fake_skill old-skill
echo "-  old-skill" >> "$STATE"
assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "old-skill skill"
step
assert_eq 0 "$RUN_STATUS" "status after keeping a stale skill"
assert_contains "$RUN_OUTPUT" "Kept the old-skill skill"
[ -d "$AGENTS_DIR/old-skill" ] || fail "the kept skill was removed"
assert_file_contains "$STATE" "old-skill"
assert_file_not_contains "$STUB_LOG" " remove "

# ... and removed with DOTFILES_ASSUME_YES=1
DOTFILES_ASSUME_YES=1 step
assert_eq 0 "$RUN_STATUS" "status after removing a stale skill"
assert_file_contains "$STUB_LOG" "remove --global --agent claude-code codex --yes old-skill"
[ ! -e "$AGENTS_DIR/old-skill" ] || fail "the stale skill is still installed"
assert_file_not_contains "$STATE" "old-skill"
assert_exit 0 "$BASH" "$STEP" --status

# A skill added by hand isn't recorded, offered, or removed
fake_skill mine
DOTFILES_ASSUME_YES=1 step
assert_file_not_contains "$STUB_LOG" " remove "
[ -d "$AGENTS_DIR/mine" ] || fail "a hand-added skill was removed"
assert_file_not_contains "$STATE" "mine"

# A failed add still removes stale skills, then fails the step. The record loses the removed
# skill, and gains the repo skills whose copies match, but not tdd, which the add may not have
# installed.
fake_skill old-skill
printf -- '-  %s\n' grill old-skill > "$STATE"
echo "drift" >> "$AGENTS_DIR/tdd/SKILL.md"
NPX_FAIL=1 DOTFILES_ASSUME_YES=1 step
assert_eq 1 "$RUN_STATUS" "status after a failed add"
assert_file_contains "$STUB_LOG" "remove --global --agent claude-code codex --yes old-skill"
[ ! -e "$AGENTS_DIR/old-skill" ] || fail "a failed add left the stale skill installed"
assert_eq "grill interrogate" "$(awk '{ print $2 }' "$STATE" | paste -sd ' ' -)" "the record after a failed add"
step

# Another agent that shares ~/.agents/skills (Zed): the CLI leaves the shared copy, and the step
# removes it too
mkdir -p "$HOME/.config/zed"
fake_skill old-skill
echo "-  old-skill" >> "$STATE"
DOTFILES_ASSUME_YES=1 step
assert_eq 0 "$RUN_STATUS" "status after removing a stale skill Zed shares"
[ ! -e "$AGENTS_DIR/old-skill" ] || fail "the shared copy of the stale skill is still there"
[ ! -e "$CLAUDE_DIR/old-skill" ] && [ ! -L "$CLAUDE_DIR/old-skill" ] || fail "the Claude Code link is still there"
assert_file_not_contains "$STATE" "old-skill"
rm -rf "$HOME/.config/zed"

# A failed remove fails the step, leaves the skill, and keeps it in the record for the next run
fake_skill old-skill
echo "-  old-skill" >> "$STATE"
NPX_REMOVE_FAIL=1 DOTFILES_ASSUME_YES=1 step
assert_eq 1 "$RUN_STATUS" "status after a failed remove"
assert_contains "$RUN_OUTPUT" "old-skill"
assert_file_contains "$STATE" "old-skill"
DOTFILES_ASSUME_YES=1 step
assert_eq 0 "$RUN_STATUS" "status after removing it again"
assert_file_not_contains "$STATE" "old-skill"

# A failed write of the record fails the step and leaves the old record whole
echo "-  old-skill" >> "$STATE"
cp "$STATE" "$SANDBOX/state"
chmod 500 "$(dirname "$STATE")"
step
chmod 700 "$(dirname "$STATE")"
assert_eq 1 "$RUN_STATUS" "status after a failed record write"
assert_contains "$RUN_OUTPUT" "Couldn't record the installed skills"
assert_eq "$(cat "$SANDBOX/state")" "$(cat "$STATE")" "the record after a failed write"
step

# Edited copies. The backups go under the state dir, not into a skills dir.
HASHES="$STATE"
rm -rf "$BACKUPS"
# The installed copies match the repo, so each has a hash
for name in tdd grill interrogate; do
    hashed "$name" || fail "no hash recorded for $name"
done

# An edited copy is backed up without a terminal, then replaced
echo "my edit" >> "$AGENTS_DIR/tdd/SKILL.md"
step
assert_eq 0 "$RUN_STATUS" "status after backing up an edited copy"
assert_eq 1 "$(backups tdd | wc -l | tr -d ' ')" "backups of the edited tdd"
assert_file_contains "$(backups tdd)/SKILL.md" "my edit"
assert_contains "$RUN_OUTPUT" "Backed up $AGENTS_DIR/tdd to $BACKUPS/tdd."
assert_file_not_contains "$AGENTS_DIR/tdd/SKILL.md" "my edit"

# Edited again in the same second, it gets a second backup rather than overwrite the first. date
# gives the backup's timestamp, so the step's second is the one the first backup has.
echo "my edit" >> "$AGENTS_DIR/tdd/SKILL.md"
stub date '[ "$*" != +%Y%m%d-%H%M%S ] || { echo 20260102-030405; exit; }
exec '"$(command -v date)"' "$@"'
mkdir -p "$BACKUPS/tdd.20260102-030405"
step
rm "$STUB_DIR/date"
assert_contains "$RUN_OUTPUT" "Backed up $AGENTS_DIR/tdd to $BACKUPS/tdd.20260102-030405-2"
assert_file_contains "$BACKUPS/tdd.20260102-030405-2/SKILL.md" "my edit"
rm -rf "$BACKUPS"

# With a terminal, the backup question reads its answer from the terminal, not from the list of
# skills the step loops over. A file of answers stands in for the terminal.
answer_yes_with_terminal() {
    # shellcheck source=../ai_tools/skills/install.sh
    source "$STEP"
    _stubs_first
    # shellcheck disable=SC2329 # confirm calls it
    is_interactive() { true; }
    install_skills < <(printf 'y\n')
}
echo "my edit" >> "$AGENTS_DIR/tdd/SKILL.md"
: > "$STUB_LOG"
run answer_yes_with_terminal
assert_eq 0 "$RUN_STATUS" "status after answering the backup question"
assert_eq 1 "$(backups tdd | wc -l | tr -d ' ')" "backups after answering yes"
rm -rf "$BACKUPS"

# An outdated copy that setup installed, as after a repo update, is replaced without a backup
echo "older version" >> "$AGENTS_DIR/tdd/SKILL.md"
grep -v '  tdd$' "$HASHES" > "$SANDBOX/hashes"
(
    # shellcheck source=../lib/common.sh
    source "$REPO_DIR/lib/common.sh"
    # shellcheck source=../ai_tools/skills/lib/hash.sh
    source "$REPO_DIR/ai_tools/skills/lib/hash.sh"
    printf '%s  tdd\n' "$(dir_sha256 "$AGENTS_DIR/tdd")"
) >> "$SANDBOX/hashes"
mv "$SANDBOX/hashes" "$HASHES"
step
assert_file_contains "$STUB_LOG" " add "
assert_eq "" "$(backups tdd)" "backups of an unedited outdated copy"
assert_not_contains "$RUN_OUTPUT" "Backed up"
assert_file_not_contains "$AGENTS_DIR/tdd/SKILL.md" "older version"

# A real directory where Claude Code's link goes is backed up, unless it matches the repo
rm "$CLAUDE_DIR/grill" "$CLAUDE_DIR/tdd"
cp -R "$AGENTS_DIR/grill" "$CLAUDE_DIR/grill"
echo "my edit" >> "$CLAUDE_DIR/grill/SKILL.md"
cp -R "$AGENTS_DIR/tdd" "$CLAUDE_DIR/tdd"
step
assert_eq 1 "$(backups grill.claude | wc -l | tr -d ' ')" "backups of Claude Code's grill dir"
assert_file_contains "$(backups grill.claude)/SKILL.md" "my edit"
assert_eq "" "$(backups tdd.claude)" "backups of Claude Code's tdd dir, which matched the repo"
[ -L "$CLAUDE_DIR/grill" ] || fail "Claude Code's grill dir wasn't replaced with a link"
rm -rf "$BACKUPS"

# A failed backup leaves that skill out of the add, so its edits survive, and fails the step
echo "my edit" >> "$AGENTS_DIR/tdd/SKILL.md"
echo "drift" >> "$AGENTS_DIR/grill/SKILL.md"
mkdir -p "$(dirname "$BACKUPS")"
: > "$BACKUPS"
DOTFILES_BACKUP=no step
assert_eq 0 "$RUN_STATUS" "status with --no-backup and an unwritable backup dir"
echo "my edit" >> "$AGENTS_DIR/tdd/SKILL.md"
# A repo change to grill, whose copy is what setup installed, is still added
echo "drift" >> "$FIXTURE/ai_tools/skills/productivity/grill/SKILL.md"
step
assert_eq 1 "$RUN_STATUS" "status after a failed backup"
assert_contains "$RUN_OUTPUT" "Couldn't back up $AGENTS_DIR/tdd"
assert_file_contains "$STUB_LOG" "--skill grill --yes"
assert_file_contains "$AGENTS_DIR/tdd/SKILL.md" "my edit"
rm -f "$BACKUPS"
step
assert_eq 0 "$RUN_STATUS" "status once the backup works"
assert_file_contains "$STUB_LOG" "--skill tdd --yes"
assert_file_contains "$(backups tdd)/SKILL.md" "my edit"
rm -rf "$BACKUPS"

# Without a record, copies that match the repo aren't backed up, and get recorded
rm "$HASHES"
echo "drift" >> "$AGENTS_DIR/grill/SKILL.md"
step
assert_eq "" "$(backups tdd)" "backups of a matching copy with no record"
hashed tdd || fail "a matching copy with no record wasn't recorded"

# Too old a Node.js fails the step, and --status points at the runtimes step. 22.20 is old enough
# for the skills CLI's engines field, but not for the step.
NODE_VERSION=v22.20.0 step
assert_eq 1 "$RUN_STATUS" "status with Node.js v22.20.0"
assert_contains "$RUN_OUTPUT" "needs Node.js 24 or newer, not v22.20.0"
NODE_VERSION=v22.20.0 assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "bash setup.sh runtimes"

# CLAUDE_CONFIG_DIR elsewhere: the skills are for Codex only, and ~/.claude/skills is left alone
rm -rf "$AGENTS_DIR" "$CLAUDE_DIR" "$STATE"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude-config"
step
assert_eq 0 "$RUN_STATUS" "status with CLAUDE_CONFIG_DIR set"
assert_contains "$RUN_OUTPUT" "so the skills are for Codex only"
assert_file_contains "$STUB_LOG" "--global --agent codex --skill"
[ -f "$AGENTS_DIR/tdd/SKILL.md" ] || fail "tdd wasn't installed for Codex"
[ ! -e "$CLAUDE_DIR" ] || fail "$CLAUDE_DIR was written with CLAUDE_CONFIG_DIR set"
assert_exit 0 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "skipped    Skills for Claude Code: CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR"
unset CLAUDE_CONFIG_DIR

# A zero exit from the skills CLI does not prove that each copy succeeded.
rm -rf "$AGENTS_DIR/tdd"
cp "$STATE" "$SANDBOX/state-before-partial-add"
NPX_SKIP=tdd step
assert_eq 1 "$RUN_STATUS" "partial installation's status"
assert_eq "$(cat "$SANDBOX/state-before-partial-add")" "$(cat "$STATE")" "failed add's record"
step
assert_eq 0 "$RUN_STATUS" "retry after partial installation"

# A failed hash must hold an existing copy, even when its parent can be replaced.
echo 'unreadable edit' >> "$AGENTS_DIR/tdd/SKILL.md"
chmod 000 "$AGENTS_DIR/tdd/SKILL.md"
step
chmod 600 "$AGENTS_DIR/tdd/SKILL.md"
assert_eq 1 "$RUN_STATUS" "unreadable installed skill's status"
assert_file_contains "$AGENTS_DIR/tdd/SKILL.md" 'unreadable edit'
assert_contains "$RUN_OUTPUT" "couldn't be backed up"
chmod 644 "$AGENTS_DIR/tdd/SKILL.md"
step

# A recorded name that isn't a plain skill name is never offered or removed, since the step removes
# a stale skill's dirs with rm -rf
mkdir -p "$HOME/Documents/keep"
echo "-  ../../Documents" >> "$STATE"
DOTFILES_ASSUME_YES=1 step
assert_eq 0 "$RUN_STATUS" "status with a bad name in the record"
assert_file_not_contains "$STUB_LOG" " remove "
[ -d "$HOME/Documents/keep" ] || fail "a bad recorded name removed a directory"
assert_file_not_contains "$STATE" "Documents"

# A repo skill whose name isn't one is skipped, failing the step, and the rest are still added
mkdir -p "$FIXTURE/ai_tools/skills/productivity/bad"
printf -- '---\nname: ../bad\n---\n' > "$FIXTURE/ai_tools/skills/productivity/bad/SKILL.md"
echo "drift" >> "$AGENTS_DIR/grill/SKILL.md"
step
assert_eq 1 "$RUN_STATUS" "status with a bad skill name"
assert_contains "$RUN_OUTPUT" "names its skill '../bad'"
assert_file_contains "$STUB_LOG" "--skill grill --yes"
assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "one isn't lowercase letters, digits, and dashes"
rm -rf "$FIXTURE/ai_tools/skills/productivity/bad"

# Two skills with one name fail the step, naming both files, and only the first, by path, is
# installed. Otherwise each run would install one over the other.
mkdir -p "$FIXTURE/ai_tools/skills/productivity/zz-grill"
printf -- '---\nname: grill\n---\ncopy\n' > "$FIXTURE/ai_tools/skills/productivity/zz-grill/SKILL.md"
step
assert_eq 1 "$RUN_STATUS" "status with two skills named grill"
assert_contains "$RUN_OUTPUT" "ai_tools/skills/productivity/zz-grill/SKILL.md names the skill 'grill', as ai_tools/skills/productivity/grill/SKILL.md does; skipping it."
assert_file_not_contains "$STUB_LOG" " add "
assert_file_not_contains "$AGENTS_DIR/grill/SKILL.md" "copy"
assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "Skill names in ai_tools/skills"
rm -rf "$FIXTURE/ai_tools/skills/productivity/zz-grill"

# Run from inside a project that has its own skills package, at the pinned version, the step runs
# the skills CLI from an empty directory of its own, for add and for remove, so npm can't pick the
# project's package or its .npmrc. The directory is gone afterwards.
PROJECT="$SANDBOX/project"
mkdir -p "$PROJECT/node_modules/.bin"
printf '{ "dependencies": { "skills": "%s" } }\n' "$(sed -n 's/^SKILLS_CLI="skills@\(.*\)"$/\1/p' "$STEP")" > "$PROJECT/package.json"
printf '%s\n' '#!/bin/bash' "touch '$SANDBOX/counterfeit-ran'" > "$PROJECT/node_modules/.bin/skills"
chmod +x "$PROJECT/node_modules/.bin/skills"
echo 'registry=http://127.0.0.1:9/' > "$PROJECT/.npmrc"
echo "drift" >> "$AGENTS_DIR/grill/SKILL.md"
fake_skill old-skill
echo "-  old-skill" >> "$STATE"
: > "$NPX_ENV_LOG"
(cd "$PROJECT" && DOTFILES_ASSUME_YES=1 step)
assert_file_contains "$STUB_LOG" "--skill grill --yes"
assert_file_contains "$STUB_LOG" "remove --global --agent claude-code codex --yes old-skill"
[ ! -e "$SANDBOX/counterfeit-ran" ] || fail "the project's skills package ran"
assert_eq 2 "$(wc -l < "$NPX_ENV_LOG" | tr -d ' ')" "skills CLI runs"
while IFS='|' read -r cwd userconfig; do
    case "$cwd/" in "$PROJECT"/*) fail "the skills CLI ran in the project, $cwd" ;; esac
    [ "$(dirname "$userconfig")" = "$cwd" ] || fail "npm_config_userconfig is $userconfig, outside $cwd"
    [ ! -e "$cwd" ] || fail "the skills CLI's directory $cwd is still there"
done < "$NPX_ENV_LOG"
test_done
