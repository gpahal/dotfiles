#!/bin/bash
# shellcheck disable=SC2088 # ~ in the output it checks

# scripts/copy-back.sh: copying edited configs back into the repo. It writes into the repo it's in,
# so it runs on a copy committed to a new git repo.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v git &>/dev/null || skip "git isn't installed"

repo="$SANDBOX/repo"
mkdir -p "$repo"
git -C "$REPO_DIR" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [ ! -f "$REPO_DIR/$f" ] || printf '%s\0' "$f"; done |
    (cd "$REPO_DIR" && tar --null -T - -cf -) | tar -C "$repo" -xf -
copy_back="$repo/scripts/copy-back.sh"
# The ubuntu step's root files go under the sandbox, not this machine's /etc and /usr/local
sed -E -i.bak "s#^(SMARTD_HOOK|UPS_NOTIFY|NTFY_LIB)=/#\1=$SANDBOX/root/#" \
    "$repo/ubuntu/lib/paths.sh" "$repo/ubuntu/install.sh"
rm "$repo/ubuntu/lib/paths.sh.bak" "$repo/ubuntu/install.sh.bak"
git -C "$repo" init -q
git -C "$repo" add -A
git_commit "$repo" -m initial

commit_all() {
    git -C "$repo" add -A
    git_commit "$repo" -m "$1"
}

assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Every installed config matches the repo's."

printf 'edited = 1\n' > "$HOME/.editorconfig"
cp "$repo/vim/vimrc" "$HOME/.vimrc"
cp "$repo/editorconfig/editorconfig" "$SANDBOX/editorconfig"

assert_exit 0 bash "$copy_back" --dry-run
assert_contains "$RUN_OUTPUT" "~/.editorconfig differs from editorconfig/editorconfig"
assert_not_contains "$RUN_OUTPUT" ".vimrc"
assert_exit 0 cmp -s "$SANDBOX/editorconfig" "$repo/editorconfig/editorconfig"

assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "+edited = 1"
assert_not_contains "$RUN_OUTPUT" ".vimrc"
assert_eq "edited = 1" "$(cat "$repo/editorconfig/editorconfig")" "the repo's copy"

assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Every installed config matches the repo's."
commit_all "editorconfig"

# A repo file with uncommitted changes, or untracked, is skipped and fails the run
printf 'repo edit\n' > "$repo/editorconfig/editorconfig"
printf 'home edit\n' > "$HOME/.editorconfig"
assert_exit 1 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Skipped ~/.editorconfig"
assert_eq "repo edit" "$(cat "$repo/editorconfig/editorconfig")" "the repo's uncommitted edit"
git -C "$repo" rm -q --cached editorconfig/editorconfig
assert_exit 1 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Skipped ~/.editorconfig"
assert_eq "repo edit" "$(cat "$repo/editorconfig/editorconfig")" "the repo's untracked file"
commit_all "repo edit"
assert_exit 0 bash "$copy_back"
assert_eq "home edit" "$(cat "$repo/editorconfig/editorconfig")" "the repo's copy once committed"
commit_all "home edit"

# Two installed copies of the user instructions: agreeing ones count once, differing ones fail
mkdir -p "$HOME/.claude" "$HOME/.codex"
printf 'mine\n' > "$HOME/.claude/CLAUDE.md"
printf 'mine\n' > "$HOME/.codex/AGENTS.md"
assert_exit 0 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "Copied 1 file(s) back."
assert_eq "mine" "$(cat "$repo/ai_tools/user-instructions.md")" "the repo's user instructions"
commit_all "mine"

# One edited copy is taken; the unedited one isn't a conflict
printf 'edited\n' > "$HOME/.claude/CLAUDE.md"
assert_exit 0 bash "$copy_back" --dry-run
assert_contains "$RUN_OUTPUT" "~/.claude/CLAUDE.md differs from ai_tools/user-instructions.md"
assert_not_contains "$RUN_OUTPUT" "AGENTS.md"
assert_exit 0 bash "$copy_back"
assert_eq "edited" "$(cat "$repo/ai_tools/user-instructions.md")" "the repo's user instructions"
commit_all "edited"
cp "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md"

printf 'claude\n' > "$HOME/.claude/CLAUDE.md"
printf 'codex\n' > "$HOME/.codex/AGENTS.md"
assert_exit 1 bash "$copy_back"
assert_contains "$RUN_OUTPUT" "~/.codex/AGENTS.md differs from ~/.claude/CLAUDE.md"
assert_eq "claude" "$(cat "$repo/ai_tools/user-instructions.md")" "the repo's user instructions"
test_done
