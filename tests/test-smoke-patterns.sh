#!/bin/bash
set -euo pipefail

# scripts/test-ubuntu.sh's patterns match t3-code's real status lines, so `just test-ubuntu`
# doesn't fail on correct behavior.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
smoke_pattern() {
    sed -n "s/^$1='\(.*\)'\$/\1/p" "$REPO_DIR/scripts/test-ubuntu.sh"
}
pattern="$(smoke_pattern T3_MANUAL_SERVE_STATUS)"
[ -n "$pattern" ] || fail "scripts/test-ubuntu.sh sets no T3_MANUAL_SERVE_STATUS"
idle_pattern="$(smoke_pattern T3_IDLE_SERVICE_STATUS)"
[ -n "$idle_pattern" ] || fail "scripts/test-ubuntu.sh sets no T3_IDLE_SERVICE_STATUS"

load_script ai_tools/t3-code/install.sh
replace_fn t3_code_other_servers 'echo "304 manual $HOME/.local/bin/t3 serve --port 3780"'
run t3_code_status_other_servers
grep -qE -- "$pattern" <<< "$RUN_OUTPUT" ||
    fail "T3_MANUAL_SERVE_STATUS doesn't match t3-code's status line: $RUN_OUTPUT"

mkdir -p "$(dirname "$T3_CODE_SERVICE_UNIT")"
touch "$T3_CODE_SERVICE_UNIT"
replace_fn t3_code_service_running_now 'true'
replace_fn t3_code_service_serving_nothing 'true'
run t3_code_status_service
grep -qE -- "$idle_pattern" <<< "$RUN_OUTPUT" ||
    fail "T3_IDLE_SERVICE_STATUS doesn't match t3-code's status line: $RUN_OUTPUT"
test_done
