#!/bin/bash
# The test replaces is_macos and is_ubuntu, which missing_cmd_hint calls
# shellcheck disable=SC2329
set -euo pipefail

# missing_cmd_hint says how to get a missing command: the homebrew step for most, which uses apt
# for the UBUNTU_COMMANDS on Ubuntu, and openssh-client for ssh-keygen, which macOS ships.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

as_ubuntu() {
    is_macos() { false; }
    is_ubuntu() { true; }
}
as_macos() {
    is_macos() { true; }
    is_ubuntu() { false; }
}

as_ubuntu
assert_eq "ssh-keygen isn't installed. Install it with: sudo apt install openssh-client" \
    "$(missing_cmd_hint ssh-keygen)" "ssh-keygen's hint on Ubuntu"
assert_eq "jq isn't installed. Run bash setup.sh homebrew first, which installs it with apt." \
    "$(missing_cmd_hint jq)" "jq's hint on Ubuntu"
assert_eq "mise isn't installed. Run bash setup.sh homebrew first." \
    "$(missing_cmd_hint mise)" "mise's hint on Ubuntu"

as_macos
assert_eq "ssh-keygen is part of macOS; check your PATH." \
    "$(missing_cmd_hint ssh-keygen)" "ssh-keygen's hint on macOS"
assert_eq "jq isn't installed. Run bash setup.sh homebrew first." \
    "$(missing_cmd_hint jq)" "jq's hint on macOS"
test_done
