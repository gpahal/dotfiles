#!/bin/bash
set -euo pipefail

# scripts/check-test-overrides.sh reports, as file:line: name, a test line that redefines a
# function a repo lib defines, but not one in a heredoc body, such as a fake step a test writes.
# It runs on a small fake repo.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

repo="$SANDBOX/repo"
mkdir -p "$repo/scripts" "$repo/lib" "$repo/tests"
cp "$REPO_DIR/scripts/check-test-overrides.sh" "$repo/scripts/"
printf '%s\n' 'repo_fn() {' '    :' '}' 'main() {' '    :' '}' 'status() {' '    :' '}' > "$repo/lib/common.sh"
check="$repo/scripts/check-test-overrides.sh"

# A fake step in a heredoc may define main and status
printf '%s\n' "cat > step.sh << 'EOF'" 'main() {' '    :' '}' 'status() { :; }' 'EOF' > "$repo/tests/test-a.sh"
assert_exit 0 bash "$check"

# A bare override is reported with its file and line
printf '%s\n' 'x=1' 'repo_fn() { :; }' > "$repo/tests/test-b.sh"
assert_exit 1 bash "$check"
assert_contains "$RUN_OUTPUT" "tests/test-b.sh:2: repo_fn"
assert_not_contains "$RUN_OUTPUT" "test-a.sh"

# So is one after a quoted stub body whose heredoc ends with the closing quote
printf '%s\n' "stub foo 'cat << WORD" 'text' "WORD'" 'repo_fn() { :; }' > "$repo/tests/test-b.sh"
assert_exit 1 bash "$check"
assert_contains "$RUN_OUTPUT" "tests/test-b.sh:4: repo_fn"
test_done
