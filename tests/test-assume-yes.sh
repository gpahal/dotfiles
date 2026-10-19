#!/bin/bash
set -euo pipefail

# DOTFILES_ASSUME_YES=1 makes confirm say yes without a terminal, for throwaway test machines.
# test-ai-manual-steps.sh covers manual-steps opening nothing with DOTFILES_ASSUME_YES=1.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

assert_exit 1 confirm "Proceed?"
export DOTFILES_ASSUME_YES=1
assert_exit 0 confirm "Proceed?"
assert_eq "Proceed? yes (DOTFILES_ASSUME_YES)" "$RUN_OUTPUT" "confirm's output"
DOTFILES_ASSUME_YES=0
assert_exit 1 confirm "Proceed?"

# confirm asks whenever stdin is a terminal, even with stdout piped, as in bash setup.sh | tee log.
# script gives the command a terminal; is_interactive then runs with stdout sent to a file.
unset DOTFILES_ASSUME_YES
answer="$SANDBOX/interactive"
check='. "$0/lib/common.sh"; if is_interactive > "$1"; then echo yes > "$1"; else echo no > "$1"; fi'
if [ "$(uname -s)" == Darwin ]; then
    script -q /dev/null "$BASH" -c "$check" "$REPO_DIR" "$answer" > /dev/null
elif script --version 2>/dev/null | grep -q util-linux; then
    script -qec "$BASH -c '$check' '$REPO_DIR' '$answer'" /dev/null > /dev/null
fi
if [ -f "$answer" ]; then
    assert_eq yes "$(cat "$answer")" "is_interactive with a terminal stdin and stdout to a file"
else
    echo "Skipping the terminal check: no script command"
fi
# Without a terminal on stdin, stdout piped still means no
run bash -c 'set -o pipefail; . "$0/lib/common.sh"; confirm "Proceed?" | cat' "$REPO_DIR"
assert_eq 1 "$RUN_STATUS" "confirm's status with stdin from /dev/null and stdout piped"
test_done
