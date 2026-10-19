#!/bin/bash
set -euo pipefail

# The patterns scripts/test-ubuntu.sh matches against a step's output in the VM match what the
# step prints, so `just test-ubuntu` doesn't fail on correct behavior: t3-code's status line for a
# t3 serve started by hand, from the step's own formatter.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
pattern="$(sed -n "s/^T3_MANUAL_SERVE_STATUS='\(.*\)'\$/\1/p" "$REPO_DIR/scripts/test-ubuntu.sh")"
[ -n "$pattern" ] || fail "scripts/test-ubuntu.sh sets no T3_MANUAL_SERVE_STATUS"

load_script ai_tools/t3-code/install.sh
replace_fn t3_code_other_servers 'echo "304 manual $HOME/.local/bin/t3 serve --port 3780"'
run t3_code_status_other_servers
grep -qE -- "$pattern" <<< "$RUN_OUTPUT" ||
    fail "T3_MANUAL_SERVE_STATUS doesn't match t3-code's status line: $RUN_OUTPUT"
test_done
