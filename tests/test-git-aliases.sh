#!/bin/bash
set -euo pipefail

# git cob switches to the local branch you pick, even one a tag shares a name with. git cobr makes a
# local branch that tracks the remote branch you pick, even when another remote has a branch of the
# same name, or a local branch is named like the remote one, such as origin/feature. When the local
# branch exists, it switches to it, and warns when that branch tracks a different remote branch.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# Only the aliases, so the rest of the repo's config (pager, fsmonitor) stays out of the test
for alias in cob cobr; do
    git config --file "$HOME/.gitconfig" "alias.$alias" "$(git config --file "$REPO_DIR/git/gitconfig" "alias.$alias")"
done
# fzf picks the line $PICK, failing when it wasn't offered
stub fzf 'grep -x -- "$PICK"'

# Two remotes, each with a branch named feature
git init -q -b main "$SANDBOX/seed"
git -C "$SANDBOX/seed" commit -q --allow-empty -m one
git -C "$SANDBOX/seed" branch feature
git clone -q --bare "$SANDBOX/seed" "$SANDBOX/origin.git"
git clone -q --bare "$SANDBOX/seed" "$SANDBOX/upstream.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/repo"
cd "$SANDBOX/repo"
git remote add upstream "$SANDBOX/upstream.git"
git fetch -q upstream

PICK=upstream/feature assert_exit 0 git cobr
assert_eq feature "$(git symbolic-ref --short HEAD)" "the branch after picking upstream/feature"
assert_eq upstream/feature "$(git rev-parse --abbrev-ref 'feature@{upstream}')" "feature's upstream"

# Picking origin/feature switches to the existing feature, and says it tracks upstream/feature
git switch -q main
PICK=origin/feature assert_exit 0 git cobr
assert_eq feature "$(git symbolic-ref --short HEAD)" "the branch after picking origin/feature"
assert_eq upstream/feature "$(git rev-parse --abbrev-ref 'feature@{upstream}')" "feature's upstream after origin/feature"
assert_contains "$RUN_OUTPUT" "feature already exists and tracks upstream/feature, not origin/feature"

# A local branch literally named origin/feature2 makes origin/feature2 ambiguous, but cobr still
# makes feature2 at the remote branch's commit, tracking it
git -C "$SANDBOX/seed" commit -q --allow-empty -m two
git -C "$SANDBOX/seed" branch feature2
git -C "$SANDBOX/seed" push -q "$SANDBOX/origin.git" feature2
git fetch -q origin
git branch origin/feature2 main
PICK=origin/feature2 assert_exit 0 git cobr
assert_eq refs/heads/feature2 "$(git symbolic-ref HEAD)" "the branch after picking origin/feature2"
assert_eq "$(git rev-parse refs/remotes/origin/feature2)" "$(git rev-parse HEAD)" "feature2's commit"
assert_eq refs/remotes/origin/feature2 "$(git rev-parse --symbolic-full-name 'feature2@{upstream}')" "feature2's upstream"
git switch -q main

# git cob offers a branch a tag shares a name with by its name, and switches to it
git tag feature
PICK=feature assert_exit 0 git cob
assert_eq refs/heads/feature "$(git symbolic-ref HEAD)" "the branch after git cob"
test_done
