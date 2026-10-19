#!/bin/bash
set -euo pipefail

# Status reports a missing prerequisite as unknown, saying how to get it, instead of failing on it
# or reporting the thing it would check as missing: curl for the chrome step's check for a .deb,
# and brew for the codex cask or any other cask.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# Status reports read apt's periodic settings
stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"1\";"'

# chrome on Ubuntu, without Chrome or curl
load_script chrome/install.sh
as_os ubuntu
stub dpkg-query 'exit 1'
stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
hide curl
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unknown    google-chrome-stable from Google's .deb: curl isn't installed"
assert_not_contains "$RUN_OUTPUT" "command not found"
assert_contains "$RUN_OUTPUT" "Chrome origins allowed in unattended-upgrades"

# codex without brew, and no codex installed another way
load_script ai_tools/codex/install.sh
as_os ubuntu
hide brew codex
# Codex's sandbox works
stub bwrap
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unknown    codex: brew isn't installed"
assert_not_contains "$RUN_OUTPUT" "missing    codex (cask)"

# Any cask without brew, as the claude-desktop step reports Claude's
status_cask_unknown() {
    status_cask claude "$SANDBOX/Claude.app"
    status_result
}
assert_exit 3 status_cask_unknown
assert_contains "$RUN_OUTPUT" "unknown    claude (cask): brew isn't installed"
assert_not_contains "$RUN_OUTPUT" "missing"
test_done
