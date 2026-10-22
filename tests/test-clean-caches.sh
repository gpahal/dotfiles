#!/bin/bash
set -euo pipefail

# scripts/clean-caches.sh: lists caches with sizes, clears them only once confirmed, and reports failures.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

CACHES="$SANDBOX/caches"
# Each tool reports its cache in the sandbox and empties it when cleared
stub go '[ "$1 $2" == "env GOCACHE" ] && { echo "'"$CACHES"'/go-build"; exit 0; }
[ "$1 $2" == "clean -cache" ] && rm -rf "'"$CACHES"'/go-build"/*'
stub pnpm '[ "$1 $2" == "store path" ] && { echo "'"$CACHES"'/pnpm"; exit 0; }
[ "$1 $2" == "store prune" ] && rm -rf "'"$CACHES"'/pnpm"/*'
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

assert_exit 0 main --dry-run
for name in "Go build cache" "pnpm store" "npm cache" "Homebrew downloads" "Playwright browsers" "PyTorch downloads"; do
    assert_contains "$RUN_OUTPUT" "$name"
done
assert_contains "$RUN_OUTPUT" "$HOME/Library/Caches/ms-playwright"
assert_contains "$RUN_OUTPUT" "Total:"
assert_not_contains "$RUN_OUTPUT" "Clear them?"
assert_file_not_contains "$STUB_LOG" "clean -cache"
[ -f "$HOME/.cache/torch/blob" ] || fail "--dry-run removed the PyTorch downloads"

# Without a terminal, confirm says no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged. Run it from a terminal"
answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged."
assert_file_not_contains "$STUB_LOG" "store prune"
[ -f "$CACHES/go-build/blob" ] || fail "a declined run cleared the Go build cache"

answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "go clean -cache"
assert_file_contains "$STUB_LOG" "pnpm store prune"
assert_file_contains "$STUB_LOG" "npm cache clean --force"
assert_file_contains "$STUB_LOG" "brew cleanup --prune=all"
[ ! -e "$HOME/Library/Caches/ms-playwright" ] || fail "the Playwright browsers are still there"
[ ! -e "$HOME/.cache/torch" ] || fail "the PyTorch downloads are still there"
assert_contains "$RUN_OUTPUT" "Freed"
assert_exit 0 main --dry-run
assert_contains "$RUN_OUTPUT" "No caches to clear."

# Ubuntu keeps Playwright's browsers under ~/.cache; PLAYWRIGHT_BROWSERS_PATH=0 keeps them in projects
as_os ubuntu
mkdir -p "$HOME/.cache/ms-playwright"
touch "$HOME/.cache/ms-playwright/chromium"
assert_exit 0 main --dry-run
assert_contains "$RUN_OUTPUT" "$HOME/.cache/ms-playwright"
PLAYWRIGHT_BROWSERS_PATH=0 run main --dry-run
assert_contains "$RUN_OUTPUT" "No caches to clear."
rm -rf "$HOME/.cache/ms-playwright"

# A missing tool is skipped; a failed one doesn't stop the rest, and fails the run
as_os macos
fill
stub pnpm '[ "$1 $2" == "store path" ] && { echo "'"$CACHES"'/pnpm"; exit 0; }
exit 1'
missing_go() {
    hide go
    assert_exit 0 main --dry-run
    assert_not_contains "$RUN_OUTPUT" "Go build cache"
    assert_contains "$RUN_OUTPUT" "npm cache"
}
subtest missing_go
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Failed: pnpm store"
assert_file_contains "$STUB_LOG" "brew cleanup --prune=all"
[ ! -e "$HOME/.cache/torch" ] || fail "a failed pnpm prune stopped the later caches"

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
assert_eq 1 "$RUN_STATUS" "main's status with HOME as a cache"
assert_contains "$RUN_OUTPUT" "Playwright browsers, PyTorch downloads"
[ -f "$HOME/.cache/torch/blob" ] || fail "a cache set to HOME cleared HOME"
as_os macos

# Each tool's cache depends on the dir it runs in, as a project's .npmrc or pnpm config makes it.
# Clearing from a project clears the caches listed, which are found from ~.
cwd_caches() {
    local where='$([ "$PWD" == "$HOME" ] && echo home || echo project)' place
    stub go 'c="'"$CACHES/go-$where"'"
case "$1 $2" in
    "env GOCACHE") echo "${GOCACHE:-$c}" ;;
    "clean -cache") rm -rf "${GOCACHE:-$c}"/* ;;
esac'
    stub pnpm 'c="'"$CACHES/pnpm-$where"'"
case "$1 $2" in
    "store path") echo "$c" ;;
    "store prune") rm -rf "$c"/* ;;
esac'
    stub npm 'c="'"$CACHES/npm-$where"'"
[ "${4:-}" != --cache ] || c="$5"
case "$1 $2 $3" in
    "config get cache") echo "$c" ;;
    "cache clean --force") rm -rf "$c"/* ;;
esac'
    for place in home project; do
        for dir in go pnpm npm; do
            mkdir -p "$CACHES/$dir-$place"
            echo blob > "$CACHES/$dir-$place/blob"
        done
    done
    mkdir -p "$SANDBOX/project"
    cd "$SANDBOX/project"
    answer yes
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "$CACHES/npm-home"
    for dir in go pnpm npm; do
        [ ! -e "$CACHES/$dir-home/blob" ] || fail "the $dir cache listed, from ~, wasn't cleared"
        [ -f "$CACHES/$dir-project/blob" ] || fail "the project's $dir cache, which wasn't listed, was cleared"
    done
}
subtest cwd_caches

assert_exit 2 main --bogus
assert_contains "$RUN_OUTPUT" "Usage: bash scripts/clean-caches.sh [--dry-run]"
test_done
