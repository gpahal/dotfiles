#!/bin/bash
# shellcheck disable=SC2034 # lib/checkout.sh reads DOTFILES_DIR

# lib/checkout.sh: the main worktree recorded from a clone, a worktree, a bare repo's worktree, and
# a plain dir; its status and apply; and upgrade in zsh/aliases.zsh finding the checkout you're in,
# else the recorded one.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script zsh/install.sh

# fake_checkout <dir>: a git repo with the files the lookups test for. Its upgrade.sh prints where
# it ran from and its arguments.
fake_checkout() {
    mkdir -p "$1/scripts" "$1/lib"
    touch "$1/setup.sh" "$1/lib/checkout.sh"
    # shellcheck disable=SC2016 # expanded when it runs
    printf '%s\n' 'echo "upgrade.sh in ${BASH_SOURCE[0]%/scripts/*}: $*"' > "$1/scripts/upgrade.sh"
    git init -q "$1"
    git -C "$1" add -A
    git_commit "$1" -m init
}

CLONE="$SANDBOX/clone"
WORKTREE="$SANDBOX/worktree"
fake_checkout "$CLONE"
git -C "$CLONE" worktree add -q -b wt "$WORKTREE"

DOTFILES_DIR="$CLONE"
assert_eq "$CLONE" "$(main_checkout)" "a clone's main checkout"
DOTFILES_DIR="$WORKTREE"
assert_eq "$CLONE" "$(main_checkout)" "a worktree's main checkout"
# A main checkout without setup.sh, as on another branch, isn't one to record
mv "$CLONE/setup.sh" "$SANDBOX/setup.sh.away"
assert_eq "$WORKTREE" "$(main_checkout)" "the main checkout of a worktree whose main checkout has no setup.sh"
mv "$SANDBOX/setup.sh.away" "$CLONE/setup.sh"
# A plain dir inside some other repo is its own checkout
mkdir -p "$CLONE/nested/plain"
DOTFILES_DIR="$CLONE/nested/plain"
assert_eq "$CLONE/nested/plain" "$(main_checkout)" "a plain dir's checkout"
# A bare repo's worktree, as there's no main checkout to run
git clone -q --bare "$CLONE" "$SANDBOX/bare.git"
git -C "$SANDBOX/bare.git" worktree add -q --detach "$SANDBOX/bare-wt"
DOTFILES_DIR="$SANDBOX/bare-wt"
assert_eq "$SANDBOX/bare-wt" "$(main_checkout)" "a bare repo's worktree's checkout"

# Status and apply, from a worktree: they record its main checkout
DOTFILES_DIR="$WORKTREE"
FILE="$HOME/.local/state/dotfiles/checkout"
assert_eq "$FILE" "$CHECKOUT_FILE" "the checkout file"
run status_checkout upgrade
assert_contains "$RUN_OUTPUT" "missing    Checkout for upgrade, recorded in ~/.local/state/dotfiles/checkout: $CLONE; none is recorded"
assert_exit 0 apply_checkout upgrade
assert_contains "$RUN_OUTPUT" "Recorded $CLONE as the checkout for upgrade, in ~/.local/state/dotfiles/checkout"
assert_eq "$CLONE" "$(cat "$FILE")" "the recorded checkout"
assert_exit 0 apply_checkout upgrade
assert_eq "" "$RUN_OUTPUT" "a second apply's output"
run status_checkout upgrade
assert_contains "$RUN_OUTPUT" "ok         Checkout for upgrade, recorded in ~/.local/state/dotfiles/checkout: $CLONE"
echo "$SANDBOX/moved" > "$FILE"
run status_checkout upgrade
assert_contains "$RUN_OUTPUT" "missing    Checkout for upgrade, recorded in ~/.local/state/dotfiles/checkout: $CLONE; it names $SANDBOX/moved"
# XDG_STATE_HOME moves it, as it does for zsh/aliases.zsh
(
    export XDG_STATE_HOME="$SANDBOX/state"
    load_script zsh/install.sh
    assert_eq "$SANDBOX/state/dotfiles/checkout" "$CHECKOUT_FILE" "the checkout file under XDG_STATE_HOME"
)

# upgrade, as zsh/aliases.zsh defines it
command -v zsh &> /dev/null || skip_rest "zsh isn't installed"
# upgrade_in <dir> [arg...]: runs upgrade from <dir>, with stderr in the output
upgrade_in() {
    local dir="$1"
    shift
    (cd "$dir" && zsh -fc 'source "$1"; shift; upgrade "$@"' zsh "$REPO_DIR/zsh/aliases.zsh" "$@" 2>&1)
}
FOREIGN="$SANDBOX/foreign"
mkdir -p "$FOREIGN/src" "$SANDBOX/elsewhere"
git init -q "$FOREIGN"
DOTFILES_DIR="$CLONE"
assert_exit 0 apply_checkout upgrade

# The checkout or worktree you're in, from any of its dirs
mkdir -p "$WORKTREE/zsh"
assert_eq "upgrade.sh in $WORKTREE: " "$(upgrade_in "$WORKTREE/zsh")" "upgrade in a worktree"
assert_eq "upgrade.sh in $CLONE: ai-tools" "$(cd "$CLONE" &&
    zsh -fc 'source "$1"; upgrade-ai-tools' zsh "$REPO_DIR/zsh/aliases.zsh" 2>&1)" "upgrade-ai-tools in the clone"
# Else the recorded one
echo "$WORKTREE" > "$FILE"
assert_eq "upgrade.sh in $WORKTREE: " "$(upgrade_in "$SANDBOX/elsewhere")" "upgrade outside a repo"
assert_eq "upgrade.sh in $WORKTREE: " "$(upgrade_in "$FOREIGN/src")" "upgrade in another repo"
# Neither
rm -rf "$WORKTREE"
output="$(upgrade_in "$SANDBOX/elsewhere")" && fail "upgrade succeeded with the recorded checkout gone"
assert_contains "$output" "No dotfiles checkout here, or recorded in $FILE. Run bash setup.sh zsh in the repo."
rm "$FILE"
output="$(upgrade_in "$SANDBOX/elsewhere")" && fail "upgrade succeeded with nothing recorded"
assert_contains "$output" "No dotfiles checkout here, or recorded in $FILE."

test_done
