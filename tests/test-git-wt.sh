#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export PATH="$REPO_DIR/git/bin:$PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

commit_in() {
    git -C "$1" commit -q --allow-empty -m "$2"
}

# other_key <checkout>: resolve only the parent, since a bare repo's stand-in checkout needn't exist
other_key() {
    local path
    path="$(CDPATH='' cd -P -- "$(dirname "$1")" && pwd)/${1##*/}"
    printf '_/%s-%s\n' "${path##*/}" "$(printf '%s' "$path" | git hash-object --stdin | cut -c1-8)"
}

git init -q -b main "$SANDBOX/seed"
commit_in "$SANDBOX/seed" pushed
git clone -q --bare "$SANDBOX/seed" "$SANDBOX/origin.git"
mkdir -p "$HOME/Dev/x"
git clone -q "$SANDBOX/origin.git" "$HOME/Dev/x/y"
repo="$HOME/Dev/x/y"
commit_in "$repo" unpushed
pushed="$(git -C "$repo" rev-parse origin/main)"
local_head="$(git -C "$repo" rev-parse HEAD)"
dir="$WORKTREES_DIR/x/y"

cd "$repo"

assert_eq "$dir/foo" "$(git wt path foo)" "path for foo"
assert_eq "$dir" "$(git wt path)" "path with no name"

assert_eq refs/remotes/origin/main "$(git wt base)" "base"

out="$(git wt add foo 2> /dev/null)" || fail "git wt add foo failed"
assert_eq "$dir/foo" "$out" "path git wt add prints"
assert_eq "foo" "$(git -C "$dir/foo" symbolic-ref --short HEAD)" "branch in the foo worktree"
assert_eq "$pushed" "$(git -C "$dir/foo" rev-parse HEAD)" "foo's base"
assert_eq "" "$(git config branch.foo.merge || true)" "foo's upstream"

out="$(git wt add foo 2> /dev/null)" || fail "a second git wt add foo failed"
assert_eq "$dir/foo" "$out" "path a second git wt add prints"

git branch old "$local_head"
out="$(git wt add old 2> /dev/null)" || fail "git wt add old failed"
assert_eq "$local_head" "$(git -C "$dir/old" rev-parse HEAD)" "old's commit"

cd "$dir/foo"
assert_eq "$dir/bar" "$(git wt path bar)" "path for bar from inside the foo worktree"
out="$(git wt add bar 2> /dev/null)" || fail "git wt add bar from inside a worktree failed"
assert_eq "$dir/bar" "$out" "path git wt add prints from inside a worktree"
cd "$repo"

out="$(git wt add t3code/abc 2> /dev/null)" || fail "git wt add t3code/abc failed"
assert_eq "$dir/t3code/abc" "$out" "path for t3code/abc"
assert_exit 0 git wt rm t3code/abc
[ ! -e "$dir/t3code" ] || fail "git wt rm left $dir/t3code"
[ -d "$dir/foo" ] || fail "git wt rm t3code/abc removed foo"

printf '.env\nnode_modules/\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
out="$(git wt add secrets 2> /dev/null)" || fail "git wt add secrets failed"
mkdir -p "$out/node_modules/x"
: > "$out/node_modules/x/index.js"
assert_exit 0 git wt rm secrets
assert_contains "$RUN_OUTPUT" "also deleting ignored build output, caches, and dependencies:
    node_modules/"
out="$(git wt add secrets 2> /dev/null)" || fail "git wt add secrets again failed"
printf 'local\n' > "$out/.env"
# status.showUntrackedFiles=no hides ignored files unless asked for
git config status.showUntrackedFiles no
assert_exit 1 git wt rm secrets
git config --unset status.showUntrackedFiles
assert_contains "$RUN_OUTPUT" "removing $out would delete:"
assert_contains "$RUN_OUTPUT" "  ignored files:
    .env"
assert_contains "$RUN_OUTPUT" "git wt rm -f secrets"
[ -f "$out/.env" ] || fail "git wt rm deleted .env"
assert_exit 0 git wt rm -f secrets
[ ! -e "$out" ] || fail "git wt rm -f left $out"
git branch -q -D secrets

git wt add merged > /dev/null 2>&1 || fail "git wt add merged failed"
assert_exit 0 git wt rm --delete-merged-branch merged
git show-ref --verify --quiet refs/heads/merged && fail "git wt rm --delete-merged-branch kept branch merged"
out="$(git wt add unmerged 2> /dev/null)" || fail "git wt add unmerged failed"
commit_in "$out" mine
assert_exit 0 git wt rm unmerged --delete-merged-branch
assert_contains "$RUN_OUTPUT" "git wt: kept branch unmerged, which has commits no other branch has"
[ ! -e "$out" ] || fail "git wt rm --delete-merged-branch left $out"
git show-ref --verify --quiet refs/heads/unmerged || fail "git wt rm --delete-merged-branch deleted branch unmerged"
git branch -q -D unmerged

git tag v2
git wt add v2 > /dev/null 2>&1 || fail "git wt add v2 failed"
out="$(git wt add v2 2> /dev/null)" || fail "a second git wt add v2, which a tag shares, failed"
assert_eq "$dir/v2" "$out" "path a second git wt add v2 prints"
assert_exit 0 git wt rm v2
git tag -d v2 > /dev/null

for other in "$SANDBOX/elsewhere/z" "$SANDBOX/another/z" "$HOME/Dev/solo"; do
    mkdir -p "$other"
    git init -q -b main "$other"
    commit_in "$other" only
    out="$(git -C "$other" wt add feat 2> /dev/null)" || fail "git wt add in $other failed"
    assert_eq "$WORKTREES_DIR/$(other_key "$other")/feat" "$out" "path for a repo at $other"
    assert_eq "$(git -C "$other" rev-parse HEAD)" "$(git -C "$out" rev-parse HEAD)" "feat's base in $other"
    assert_eq HEAD "$(git -C "$other" wt base)" "base in $other"
done
assert_contains "$(git -C "$SANDBOX/elsewhere/z" wt path)" "/_/z-" "path for a repo named z"
[ "$(git -C "$SANDBOX/elsewhere/z" wt path)" != "$(git -C "$SANDBOX/another/z" wt path)" ] ||
    fail "two repos named z share a worktrees dir"

git push -q origin "$local_head:refs/heads/remote-only"
git fetch -q
out="$(git wt add remote-only 2> /dev/null)" || fail "git wt add remote-only failed"
assert_eq "$local_head" "$(git -C "$dir/remote-only" rev-parse HEAD)" "remote-only's commit"
assert_eq "origin/remote-only" "$(git -C "$dir/remote-only" rev-parse --abbrev-ref '@{upstream}' || true)" \
    "remote-only's upstream"

git remote set-head origin -d
assert_eq refs/remotes/origin/main "$(git wt base)" "base without origin/HEAD"
out="$(git wt add nohead 2> /dev/null)" || fail "git wt add without origin/HEAD failed"
assert_eq "$pushed" "$(git -C "$dir/nohead" rev-parse HEAD)" "nohead's base"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

git push -q origin "$local_head:refs/heads/tagged-remote"
git fetch -q
git tag origin/main "$local_head~1"
git tag origin/tagged-remote "$local_head~1"
out="$(git wt add tagged 2> /dev/null)" || fail "git wt add with an origin/main tag failed"
assert_eq "$pushed" "$(git -C "$dir/tagged" rev-parse HEAD)" "tagged's base with an origin/main tag"
out="$(git wt add tagged-remote 2> /dev/null)" || fail "git wt add tagged-remote failed"
assert_eq "$local_head" "$(git -C "$dir/tagged-remote" rev-parse HEAD)" "tagged-remote's commit with a tag"
assert_eq "refs/heads/tagged-remote" "$(git config branch.tagged-remote.merge || true)" \
    "tagged-remote's upstream with a tag"
git tag -d origin/main origin/tagged-remote > /dev/null

assert_exit 1 git wt add nested/broken no-such-base
[ ! -e "$dir/nested" ] || fail "a failed git wt add left $dir/nested"
[ -d "$dir/nohead" ] || fail "a failed git wt add removed another worktree"

# --lock would make a worktree git wt rm -f can't remove
assert_exit 1 git wt add opt --lock
assert_contains "$RUN_OUTPUT" "'--lock' isn't a valid base"
[ ! -e "$dir/opt" ] || fail "git wt add with an option as its base made $dir/opt"
git show-ref --verify --quiet refs/heads/opt && fail "git wt add with an option as its base made branch opt"

out="$(git wt add gone 2> /dev/null)" || fail "git wt add gone failed"
rm -rf "$out"
out="$(git wt add gone 2> /dev/null)" || fail "git wt add after deleting the worktree by hand failed"
[ -d "$dir/gone" ] || fail "git wt add didn't recreate the deleted worktree"

for name in remote-only nohead gone; do
    assert_exit 0 git wt rm "$name"
done

# mark <name> <session>: write the files the Claude Code worktree hook leaves
mark() {
    local gitdir
    gitdir="$(git -C "$dir/$1" rev-parse --absolute-git-dir)"
    touch "$gitdir/worktree-hook-created-branch"
    printf '%s\n' "$2" > "$gitdir/worktree-hook-session"
}
for name in p-clean p-built p-cache p-changed p-committed p-draft p-link p-samelink p-linkcopy p-linkdiff \
    p-other p-unmarked p-here; do
    git wt add "$name" > /dev/null 2>&1 || fail "git wt add $name failed"
done
for name in p-clean p-built p-cache p-changed p-committed p-draft p-link p-samelink p-linkcopy p-linkdiff \
    p-here; do
    mark "$name" s1
done
mark p-other s2
mkdir -p "$dir/p-built/node_modules/x"
touch "$dir/p-built/node_modules/x/index.js"
mkdir -p "$repo/.git/info"
printf 'node_modules/\n' >> "$repo/.git/info/exclude"
mkdir -p "$dir/p-cache/.pytest_cache" "$dir/p-cache/pkg.egg-info"
touch "$dir/p-cache/.pytest_cache/README.md" "$dir/p-cache/pkg.egg-info/PKG-INFO"
printf '.pytest_cache/\n*.egg-info/\n' >> "$repo/.git/info/exclude"
echo change > "$dir/p-changed/file"
# git quotes the name with a space; zz.local, a copy sorted after it, mustn't hide it
printf '/Draft notes.txt\n/zz.local\n' >> "$repo/.git/info/exclude"
echo draft > "$dir/p-draft/Draft notes.txt"
echo same > "$repo/zz.local"
echo same > "$dir/p-draft/zz.local"
# A symlink matches only with the same target; a file matches a link by the target's content,
# as the worktree hook copies it
printf '/env-a\n/env-b\n' >> "$repo/.git/info/exclude"
for path in "$repo" "$dir/p-link" "$dir/p-samelink" "$dir/p-linkcopy" "$dir/p-linkdiff"; do
    echo same > "$path/env-a"
    echo same > "$path/env-b"
done
ln -s env-a "$repo/.env"
ln -s env-b "$dir/p-link/.env"
ln -s env-a "$dir/p-samelink/.env"
echo same > "$dir/p-linkcopy/.env"
echo other > "$dir/p-linkdiff/.env"
commit_in "$dir/p-committed" mine
# git can't remove the worktree prune runs from
out="$(cd "$dir/p-here" && git wt prune --session s1 2>&1)" || fail "git wt prune --session s1 failed: $out"
for name in p-clean p-built p-cache p-samelink p-linkcopy; do
    [ ! -e "$dir/$name" ] || fail "git wt prune --session s1 kept $name"
    git show-ref --verify --quiet "refs/heads/$name" && fail "git wt prune --session s1 kept branch $name"
done
assert_contains "$out" "git wt: removed $(cd -P "$dir" && pwd)/p-clean and branch p-clean"
for name in p-changed p-committed p-draft p-link p-linkdiff p-other p-unmarked p-here; do
    [ -d "$dir/$name" ] || fail "git wt prune --session s1 removed $name"
    git show-ref --verify --quiet "refs/heads/$name" || fail "git wt prune --session s1 deleted branch $name"
done
git wt prune 2> /dev/null || fail "git wt prune failed"
for name in p-other p-here; do
    [ ! -e "$dir/$name" ] || fail "git wt prune kept $name"
done
for name in p-changed p-committed p-draft p-link p-unmarked; do
    [ -d "$dir/$name" ] || fail "git wt prune removed $name"
done
assert_exit 1 git wt prune --session
assert_exit 1 git wt prune --bogus
for name in p-changed p-committed p-draft p-link p-unmarked; do
    git wt rm -f "$name" 2> /dev/null
done
rm "$repo/zz.local" "$repo/.env" "$repo/env-a" "$repo/env-b"

git init -q -b main --separate-git-dir "$SANDBOX/sep.git" "$HOME/Dev/x/sep"
commit_in "$HOME/Dev/x/sep" only
out="$(git -C "$HOME/Dev/x/sep" wt add feat 2> /dev/null)" || fail "git wt add with a separate git dir failed"
assert_eq "$WORKTREES_DIR/x/sep/feat" "$out" "path for a repo with a separate git dir"
# Its git dir doesn't record the checkout, so a linked worktree can't find it
for args in path list "rm feat"; do
    # shellcheck disable=SC2086 # split the arguments
    assert_exit 1 git -C "$out" wt $args
    assert_contains "$RUN_OUTPUT" "run git wt from the main checkout of a --separate-git-dir repo"
done
[ -d "$out" ] || fail "git wt rm removed a worktree it couldn't place"

mkdir -p "$HOME/Dev/x/bare"
git clone -q --bare "$SANDBOX/origin.git" "$HOME/Dev/x/bare/.bare"
echo "gitdir: ./.bare" > "$HOME/Dev/x/bare/.git"
git -C "$HOME/Dev/x/bare" worktree add -q "$HOME/Dev/x/bare/main" main 2> /dev/null
assert_eq "$WORKTREES_DIR/x/bare" "$(git -C "$HOME/Dev/x/bare" wt path)" "path for a bare repo"
assert_eq "$WORKTREES_DIR/x/bare/f" "$(git -C "$HOME/Dev/x/bare/main" wt path f)" \
    "path from a bare repo's worktree"

# git registers the resolved path of a symlinked $WORKTREES_DIR
git clone -q "$SANDBOX/origin.git" "$HOME/Dev/x/s"
mkdir -p "$SANDBOX/real-worktrees"
ln -s "$SANDBOX/real-worktrees" "$SANDBOX/linked-worktrees"
out="$(WORKTREES_DIR="$SANDBOX/linked-worktrees" git -C "$HOME/Dev/x/s" wt add feat 2> /dev/null)" ||
    fail "git wt add behind a symlink failed"
rm -rf "$SANDBOX/linked-worktrees/x/s"
out="$(WORKTREES_DIR="$SANDBOX/linked-worktrees" git -C "$HOME/Dev/x/s" wt add feat 2> /dev/null)" ||
    fail "git wt add after deleting the repo's worktree directory failed"
assert_eq "$SANDBOX/linked-worktrees/x/s/feat" "$out" "path git wt add prints behind a symlink"
assert_eq feat "$(git -C "$out" symbolic-ref --short HEAD)" "branch in the re-added worktree"
touch "$(git -C "$out" rev-parse --absolute-git-dir)/worktree-hook-created-branch"
WORKTREES_DIR="$SANDBOX/linked-worktrees" git -C "$HOME/Dev/x/s" wt prune 2> /dev/null ||
    fail "git wt prune behind a symlink failed"
[ ! -e "$SANDBOX/real-worktrees/x" ] || fail "git wt prune behind a symlink left $SANDBOX/real-worktrees/x"
[ -d "$SANDBOX/real-worktrees" ] || fail "git wt prune behind a symlink removed \$WORKTREES_DIR"

for bad in worktrees / //; do
    WORKTREES_DIR="$bad" assert_exit 1 git -C "$HOME/Dev/x/s" wt path
    assert_contains "$RUN_OUTPUT" "WORKTREES_DIR must be an absolute path other than /"
done
test_done
