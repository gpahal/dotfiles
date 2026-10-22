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

assert_exit 2 main --bogus
assert_contains "$RUN_OUTPUT" "Usage: bash scripts/clean-caches.sh [--dry-run]"
test_done
