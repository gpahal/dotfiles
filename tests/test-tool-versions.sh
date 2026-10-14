#!/bin/bash
set -euo pipefail

# scripts/check-tool-versions.sh passes when each tool is at its declared minimum, and fails,
# naming the tool, when one is older, missing, or Ubuntu's other yq.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

check="$REPO_DIR/scripts/check-tool-versions.sh"
# Stub every tool at its declared minimum
at_minimum() {
    stub jq 'echo jq-1.8.1'
    stub yq 'echo "yq (https://github.com/mikefarah/yq/) version v4.54.1"'
    stub just 'echo just 1.45.0'
    stub zsh 'echo "zsh 5.9 (x86_64-ubuntu-linux-gnu)"'
    stub tmux 'echo tmux 3.6'
    stub vim 'echo "VIM - Vi IMproved 9.1 (2024 Jan 02, compiled Apr 01 2025 20:12:31)"'
    stub git 'echo git version 2.53.0'
}

at_minimum
assert_exit 0 "$BASH" "$check"
assert_contains "$RUN_OUTPUT" "jq 1.8.1 (at least 1.8.1)"

# Newer versions, including tmux's letter suffix and next- builds
stub jq 'echo jq-1.8.2'
stub tmux 'echo tmux 3.6a'
assert_exit 0 "$BASH" "$check"
stub tmux 'echo tmux next-3.9'
assert_exit 0 "$BASH" "$check"

# Older versions
at_minimum
stub jq 'echo jq-1.6'
stub yq 'echo "yq (https://github.com/mikefarah/yq/) version v4.53.6"'
stub git 'echo git version 2.9.5'
assert_exit 1 "$BASH" "$check"
assert_contains "$RUN_OUTPUT" "jq 1.6 is older than 1.8.1"
assert_contains "$RUN_OUTPUT" "yq 4.53.6 is older than 4.54.1"
assert_contains "$RUN_OUTPUT" "git 2.9.5 is older than 2.53"

# Ubuntu's apt yq, a different tool, and a missing tool
at_minimum
stub yq 'echo yq 3.1.0'
hide just
assert_exit 1 "$BASH" "$check"
assert_contains "$RUN_OUTPUT" "yq isn't mikefarah's"
assert_contains "$RUN_OUTPUT" "just isn't installed"
test_done
