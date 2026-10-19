#!/bin/bash
set -euo pipefail

# The git cob and cobr aliases, with ambiguous branch, tag, and remote names.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# Only the aliases, keeping the repo's pager and fsmonitor config out
for alias in cob cobr; do
    git config --file "$HOME/.gitconfig" "alias.$alias" "$(git config --file "$REPO_DIR/git/gitconfig" "alias.$alias")"
done
stub fzf 'grep -x -- "$PICK"'

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

git switch -q main
PICK=origin/feature assert_exit 0 git cobr
assert_eq feature "$(git symbolic-ref --short HEAD)" "the branch after picking origin/feature"
assert_eq upstream/feature "$(git rev-parse --abbrev-ref 'feature@{upstream}')" "feature's upstream after origin/feature"
assert_contains "$RUN_OUTPUT" "feature already exists and tracks upstream/feature, not origin/feature"

# A local branch named origin/feature2 makes the name ambiguous
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

git tag feature
PICK=feature assert_exit 0 git cob
assert_eq refs/heads/feature "$(git symbolic-ref HEAD)" "the branch after git cob"
test_done
