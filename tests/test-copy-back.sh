#!/bin/bash
# shellcheck disable=SC2088 # ~ in the output it checks
set -euo pipefail

# scripts/copy-back.sh copies each installed config that differs back over the repo's, printing its
# diff, and --dry-run only lists them. Files that match, or aren't installed, are left alone, and
# two installed copies of one repo file that differ fail it. It runs on a copy of the repo, since
# it writes into the one it's in.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"

repo="$SANDBOX/repo"
mkdir -p "$repo"
git -C "$REPO_DIR" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [ ! -f "$REPO_DIR/$f" ] || printf '%s\0' "$f"; done |
    (cd "$REPO_DIR" && tar --null -T - -cf -) | tar -C "$repo" -xf -
copy_back="$repo/scripts/copy-back.sh"

# Nothing installed
assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Every installed config matches the repo's."

# ~/.editorconfig edited, ~/.vimrc as the repo has it
printf 'edited = 1\n' > "$HOME/.editorconfig"
cp "$repo/vim/vimrc" "$HOME/.vimrc"
cp "$repo/editorconfig/editorconfig" "$SANDBOX/editorconfig"

assert_exit 0 bash "$copy_back" --dry-run
assert_contains "$RUN_OUTPUT" "~/.editorconfig differs from editorconfig/editorconfig"
assert_not_contains "$RUN_OUTPUT" ".vimrc"
assert_exit 0 cmp -s "$SANDBOX/editorconfig" "$repo/editorconfig/editorconfig"

assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "=== ~/.editorconfig -> editorconfig/editorconfig"
assert_contains "$RUN_OUTPUT" "+edited = 1"
assert_contains "$RUN_OUTPUT" "Copied 1 file(s) back."
assert_not_contains "$RUN_OUTPUT" ".vimrc"
assert_eq "edited = 1" "$(cat "$repo/editorconfig/editorconfig")" "the repo's copy"

# A second run finds nothing
assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Every installed config matches the repo's."

# The user instructions, installed twice: copies that agree are taken once, and copies that
# differ fail it, naming the second
mkdir -p "$HOME/.claude" "$HOME/.codex"
printf 'mine\n' > "$HOME/.claude/CLAUDE.md"
printf 'mine\n' > "$HOME/.codex/AGENTS.md"
assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Copied 1 file(s) back."
assert_eq "mine" "$(cat "$repo/ai_tools/user-instructions.md")" "the repo's user instructions"

printf 'claude\n' > "$HOME/.claude/CLAUDE.md"
printf 'codex\n' > "$HOME/.codex/AGENTS.md"
assert_exit 1 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "~/.codex/AGENTS.md differs from ~/.claude/CLAUDE.md, and both are copies of ai_tools/user-instructions.md"
assert_eq "claude" "$(cat "$repo/ai_tools/user-instructions.md")" "the repo's user instructions"

assert_exit 2 bash "$copy_back" --bogus
test_done
