#!/bin/bash
# shellcheck disable=SC2329

# setup_codex_sandbox on Ubuntu, where AppArmor can restrict bwrap's user namespaces.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script ai_tools/codex/install.sh
as_os ubuntu
stub_sudo_exec
S="$SANDBOX/state"
USERNS_RESTRICT_SYSCTL="$S/userns"
BWRAP_PROFILE="$SANDBOX/apparmor.d/bwrap-userns-restrict"

stub_apt_package bubblewrap "$S/bubblewrap"
stub apparmor_parser 'touch "'"$S"'/loaded"'
stub bwrap 'S="'"$S"'"
[ -e "$S/bubblewrap" ] && [ ! -e "$S/bwrap-broken" ] &&
    { [ "$(cat "$S/userns")" != 1 ] || [ -e "$S/loaded" ]; }'

# Usage: reset <restricted: 0 or 1> [state file]...
reset() {
    rm -rf "$S" "$(dirname "$BWRAP_PROFILE")"
    mkdir -p "$S" "$(dirname "$BWRAP_PROFILE")"
    echo "$1" > "$USERNS_RESTRICT_SYSCTL"
    shift
    local f
    for f in "$@"; do
        touch "$S/$f"
    done
    : > "$STUB_LOG"
    answer no
}
# apt-get without the environment and options lib/common.sh's apt_get adds
sudo_calls() {
    grep '^sudo' "$STUB_LOG" | sed -E -e "s|$SANDBOX|SANDBOX|g" -e 's/^sudo .*apt-get( -o [^ ]+)* /sudo apt-get /' || true
}

reset 1 bubblewrap loaded
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Codex's sandbox already works."
assert_eq "" "$(sudo_calls)" "sudo calls with a working bwrap"

reset 0 bubblewrap bwrap-broken
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "AppArmor's user namespace restriction isn't the"
assert_eq "" "$(sudo_calls)" "sudo calls with a broken bwrap"

reset 1 bubblewrap
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "sudo apt-get install --reinstall -o Dpkg::Options::=--force-confmiss apparmor"
assert_not_contains "$RUN_OUTPUT" "These need sudo"

reset 1 bubblewrap
touch "$BWRAP_PROFILE"
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Load the bwrap-userns-restrict AppArmor profile"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_eq "" "$(sudo_calls)" "sudo calls after a no"
answer yes
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Codex's sandbox works now."
assert_eq "sudo apparmor_parser -r SANDBOX/apparmor.d/bwrap-userns-restrict" "$(sudo_calls)" "sudo calls to load the profile"

# 26.04 loads the profile at boot, so it isn't reloaded
reset 1 loaded
touch "$BWRAP_PROFILE"
answer yes
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Codex's sandbox works now."
assert_eq "sudo apt-get update
sudo apt-get install -y bubblewrap" "$(sudo_calls)" "sudo calls with the profile loaded at boot"

reset 1
touch "$BWRAP_PROFILE"
answer yes
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Install bubblewrap"
assert_contains "$RUN_OUTPUT" "Codex's sandbox works now."
assert_eq "sudo apt-get update
sudo apt-get install -y bubblewrap
sudo apparmor_parser -r SANDBOX/apparmor.d/bwrap-userns-restrict" "$(sudo_calls)" "sudo calls for bubblewrap with the profile in apparmor.d"

reset 1
answer yes
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "sudo apt-get install --reinstall -o Dpkg::Options::=--force-confmiss apparmor"
assert_eq "sudo apt-get update
sudo apt-get install -y bubblewrap" "$(sudo_calls)" "sudo calls with no profile to load"

reset 1 bwrap-broken
touch "$BWRAP_PROFILE"
answer yes
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "bwrap still can't create a sandbox"
assert_contains "$(sudo_calls)" "sudo apparmor_parser -r"

test_done
