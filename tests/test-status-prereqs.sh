#!/bin/bash
set -euo pipefail

# Status reports a check whose prerequisite is missing as unknown, not missing or a crash.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"1\";"'

load_script chrome/install.sh
as_os ubuntu
stub dpkg-query 'exit 1'
stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
hide curl
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unknown    google-chrome-stable from Google's .deb: curl isn't installed"
assert_not_contains "$RUN_OUTPUT" "command not found"
assert_contains "$RUN_OUTPUT" "Chrome origins allowed in unattended-upgrades"

load_script ai_tools/codex/install.sh
as_os ubuntu
hide brew codex
stub bwrap
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unknown    codex: brew isn't installed"
assert_not_contains "$RUN_OUTPUT" "missing    codex (cask)"

status_cask_unknown() {
    status_cask claude "$SANDBOX/Claude.app"
    status_result
}
assert_exit 3 status_cask_unknown
assert_contains "$RUN_OUTPUT" "unknown    claude (cask): brew isn't installed"
assert_not_contains "$RUN_OUTPUT" "missing"
test_done
