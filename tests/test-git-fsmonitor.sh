#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The git config turns core.fsmonitor on only for repos under ~/Dev/ and their linked worktrees,
# through an include the git step installs beside it. Elsewhere, such as a throwaway repo under
# /tmp, it stays off, so git starts no daemon there.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# Logged in to GitHub; gh auth setup-git does nothing
stub gh
load_script git/install.sh
# Ubuntu's HTTPS rewrites don't matter here
as_os macos

assert_exit 0 main

fsmonitor() {
    git -C "$1" config core.fsmonitor || true
}

repo="$HOME/Dev/group/project"
git init -q "$repo"
git -C "$repo" commit -q --allow-empty -m one
git -C "$repo" worktree add -q "$HOME/.worktrees/group/project/wt"
git init -q "$SANDBOX/tmp/scratch"

assert_eq true "$(fsmonitor "$repo")" "core.fsmonitor in a repo under ~/Dev"
assert_eq true "$(fsmonitor "$HOME/.worktrees/group/project/wt")" \
    "core.fsmonitor in its linked worktree under ~/.worktrees"
assert_eq "" "$(fsmonitor "$SANDBOX/tmp/scratch")" "core.fsmonitor in a repo outside ~/Dev"
test_done
