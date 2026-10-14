#!/bin/bash
set -euo pipefail

# Every step in each runner's STEPS, on macOS and on Ubuntu, resolves through step_script to a
# script that exists, and a name outside both lists doesn't resolve. The steps come from each
# runner's --help, with uname stubbed to report the OS.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

# Set LISTED to a runner's default steps on an OS (Darwin or Linux)
runner_steps() {
    stub uname "[ \"\$1\" != -s ] || echo $2"
    assert_exit 0 "$BASH" "$REPO_DIR/$1" --help
    LISTED="$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^Steps, run in this order by default: //p')"
    [ -n "$LISTED" ] || fail "no steps read from $1 --help on $2"
}

for runner in setup.sh ai_tools/setup.sh; do
    runner_steps "$runner" Darwin
    # shellcheck disable=SC2206 # step names have no spaces
    MACOS_STEPS=($LISTED)
    runner_steps "$runner" Linux
    # shellcheck disable=SC2206
    UBUNTU_STEPS=($LISTED)
    # shellcheck disable=SC2034 # step_script reads it
    STEPS_DIR="$(dirname "$REPO_DIR/$runner")"
    for step in "${MACOS_STEPS[@]}" "${UBUNTU_STEPS[@]}"; do
        script="$(step_script "$step")" || {
            fail "$runner: step_script doesn't resolve $step"
            continue
        }
        [ -f "$script" ] || fail "$runner: $step resolves to $script, which doesn't exist"
    done
    for name in "" nope lib ../setup; do
        ! step_script "$name" > /dev/null || fail "$runner: step_script resolved \"$name\""
    done
done
test_done
