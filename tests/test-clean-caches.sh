#!/bin/bash

# scripts/clean-caches.sh: lists caches with sizes, clears them only once confirmed, and reports failures.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CACHES="$SANDBOX/caches"
# Each tool reports its cache in the sandbox and empties it when cleared
stub go '[ "$1 $2" == "env GOCACHE" ] && { echo "'"$CACHES"'/go-build"; exit 0; }
[ "$1 $2" == "clean -cache" ] && rm -rf "'"$CACHES"'/go-build"/*'
stub_pnpm() {
    stub pnpm '[ "$1 $2" == "store path" ] && { echo "'"$CACHES"'/pnpm"; exit 0; }
[ "$1 $2" == "store prune" ] && rm -rf "'"$CACHES"'/pnpm"/*'
}
stub_pnpm
stub npm '[ "$1 $2 $3" == "config get cache" ] && { echo "'"$CACHES"'/npm"; exit 0; }
[ "$1 $2 $3" == "cache clean --force" ] && rm -rf "'"$CACHES"'/npm"/*'
stub brew '[ "$1" == --cache ] && { echo "'"$CACHES"'/brew"; exit 0; }
[ "$1 $2" == "cleanup --prune=all" ] && rm -rf "'"$CACHES"'/brew"/*'

fill() {
    local dir
    for dir in "$CACHES/go-build" "$CACHES/pnpm" "$CACHES/npm" "$CACHES/brew" \
        "$HOME/Library/Caches/ms-playwright" "$HOME/.cache/torch"; do
        mkdir -p "$dir"
        head -c 4096 /dev/zero > "$dir/blob"
    done
}

load_script scripts/clean-caches.sh
as_os macos
fill

# Leaves each cache's blob or checks it's gone
kept() {
    [ -f "$1/blob" ] || fail "$2 removed $1"
}
emptied() {
    [ ! -e "$1/blob" ] || fail "$2 left $1 full"
}

assert_exit 0 main --dry-run
kept "$CACHES/go-build" "--dry-run"
kept "$HOME/.cache/torch" "--dry-run"

# Without a terminal, confirm says no
assert_exit 0 main
kept "$CACHES/go-build" "a run without a terminal"
answer no
assert_exit 0 main
kept "$CACHES/pnpm" "a declined run"

answer yes
assert_exit 0 main
for dir in "$CACHES/go-build" "$CACHES/pnpm" "$CACHES/npm" "$CACHES/brew"; do
    emptied "$dir" "a confirmed run"
done
[ ! -e "$HOME/Library/Caches/ms-playwright" ] || fail "the Playwright browsers are still there"
[ ! -e "$HOME/.cache/torch" ] || fail "the PyTorch downloads are still there"

# PLAYWRIGHT_BROWSERS_PATH=0 keeps browsers in each project, so there's no cache to clear
as_os ubuntu
mkdir -p "$HOME/.cache/ms-playwright"
touch "$HOME/.cache/ms-playwright/chromium"
PLAYWRIGHT_BROWSERS_PATH=0 run main --dry-run
assert_contains "$RUN_OUTPUT" "No caches to clear."
rm -rf "$HOME/.cache/ms-playwright"

# A failed tool doesn't stop the rest, and fails the run
as_os macos
fill
stub pnpm '[ "$1 $2" == "store path" ] && { echo "'"$CACHES"'/pnpm"; exit 0; }
exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Failed: pnpm store"
emptied "$CACHES/brew" "a failed pnpm prune"
[ ! -e "$HOME/.cache/torch" ] || fail "a failed pnpm prune stopped the later caches"
stub_pnpm

# _clear_dir resolves its dir, so no spelling of HOME, or of a dir above it, is removed
clear_dir_guard() {
    local dir
    ln -s "$HOME" "$SANDBOX/home-link"
    stub rm 'exit 1'
    for dir in "$HOME//" "$HOME/." "$SANDBOX/home-link" "$SANDBOX/home-link/" "$HOME/.." / //; do
        assert_exit 1 _clear_dir "$dir"
        assert_contains "$RUN_OUTPUT" "Not clearing $dir, which is / or holds your home folder."
    done
    assert_eq "" "$(grep '^rm' "$STUB_LOG" || true)" "rm runs for HOME or a dir above it"
    /bin/rm -f "$STUB_DIR/rm" "$SANDBOX/home-link"
}
subtest clear_dir_guard
as_os ubuntu
fill
answer yes
PLAYWRIGHT_BROWSERS_PATH="$HOME//" TORCH_HOME="$HOME/." run main
assert_eq 0 "$RUN_STATUS" "main's status with HOME as a cache"
assert_contains "$RUN_OUTPUT" "Skipping the Playwright browsers"
[ -f "$HOME/.cache/torch/blob" ] || fail "a cache set to HOME cleared HOME"

# A cache dir an env var moves outside the cache home is left alone, as it could hold your files
mkdir -p "$HOME/Documents"
echo mine > "$HOME/Documents/notes.txt"
TORCH_HOME="$HOME/Documents" run main
assert_eq 0 "$RUN_STATUS" "main's status with TORCH_HOME outside the cache home"
assert_contains "$RUN_OUTPUT" "Skipping the PyTorch downloads in $HOME/Documents"
[ -f "$HOME/Documents/notes.txt" ] || fail "TORCH_HOME=~/Documents cleared ~/Documents"
# A relative path is checked from the cwd, so it must be cleared there too, not from ~
mkdir -p "$HOME/torch" "$HOME/.cache/torch"
echo mine > "$HOME/torch/notes.txt"
echo blob > "$HOME/.cache/torch/blob"
(cd "$HOME/.cache" && TORCH_HOME=torch run main)
[ -f "$HOME/torch/notes.txt" ] || fail "TORCH_HOME=torch, run from ~/.cache, cleared ~/torch"
as_os macos

test_done
