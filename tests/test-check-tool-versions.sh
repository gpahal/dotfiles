#!/bin/bash
set -euo pipefail

# scripts/check-tool-versions.sh passes when every tool is at least its minimum, comparing each
# dot-separated part as a number, and fails naming a tool that's missing, older, whose version it
# can't read, or, for yq, that isn't mikefarah's. It checks every tool before failing.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# Stub each tool to print the version line in $SANDBOX/versions/<tool>
mkdir -p "$SANDBOX/versions"
version() {
    printf '%s\n' "$2" > "$SANDBOX/versions/$1"
}
for tool in jq yq just zsh tmux vim git; do
    stub "$tool" 'cat "'"$SANDBOX"'/versions/${0##*/}"'
done
version jq jq-1.8.1
version yq "yq (https://github.com/mikefarah/yq/) version v4.54.1"
version just "just 1.45.0"
version zsh "zsh 5.9 (arm64-apple-darwin25.0)"
version tmux "tmux 3.6a"
version vim "VIM - Vi IMproved 9.1 (2024 Jan 02, compiled Oct 1 2026 00:00:00)"
version git "git version 2.53.0"
check() {
    assert_exit "$1" "$BASH" "$REPO_DIR/scripts/check-tool-versions.sh"
}

check 0
assert_contains "$RUN_OUTPUT" "jq 1.8.1 (at least 1.8.1)"
assert_contains "$RUN_OUTPUT" "git 2.53.0 (at least 2.53)"
assert_contains "$RUN_OUTPUT" "tmux 3.6 (at least 3.6)"

# Each part compares as a number: 1.10 is newer than 1.8.1, and 2.100 is newer than 2.53
version jq jq-1.10
version git "git version 2.100"
check 0

# An older version, a version it can't read, and another yq each fail, and every tool is checked
version jq jq-1.8.0
version just "just (development build)"
version yq "yq 3.4.1"
check 1
assert_contains "$RUN_OUTPUT" "jq 1.8.0 is older than 1.8.1"
assert_contains "$RUN_OUTPUT" "Couldn't read just's version from: just (development build)"
assert_contains "$RUN_OUTPUT" "yq isn't mikefarah's"
assert_contains "$RUN_OUTPUT" "git 2.100 (at least 2.53)"
version jq jq-1.8.1
version just "just 1.45.0"
version yq "yq (https://github.com/mikefarah/yq/) version v4.54.1"

# A missing tool
hide tmux
check 1
assert_contains "$RUN_OUTPUT" "tmux isn't installed (needs at least 3.6)"
assert_contains "$RUN_OUTPUT" "vim 9.1 (at least 9.1)"

test_done
