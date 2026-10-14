#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# setup_codex_sandbox on Ubuntu: it installs bubblewrap, and when bwrap then fails because AppArmor
# restricts user namespaces, loads the bwrap-userns-restrict profile, installing it from
# apparmor-profiles when it isn't in /etc/apparmor.d yet. It fails when bwrap is broken for another
# reason, when no profile can be had, or when bwrap still fails after setup.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/codex/install.sh
is_macos() { false; }
is_ubuntu() { true; }
stub sudo 'exec env "$@"'
S="$SANDBOX/state"
USERNS_RESTRICT_SYSCTL="$S/userns"
BWRAP_PROFILE_SOURCE="$SANDBOX/extra-profiles/bwrap-userns-restrict"
BWRAP_PROFILE="$SANDBOX/apparmor.d/bwrap-userns-restrict"

# bubblewrap is installed once $S/bubblewrap exists, and apt-get install adds it. bwrap works when
# it's installed and the namespace restriction is off or the profile is loaded, unless
# $S/bwrap-broken exists. apt-get installing apparmor-profiles adds the profile's source.
# apparmor_parser loads the profile. apt-cache offers apparmor-profiles unless $S/no-profiles
# exists.
stub dpkg-query '[ "${!#}" != bubblewrap ] || [ ! -e "'"$S"'/bubblewrap" ] || echo "install ok installed"'
stub apt-get '[ "$3" == install ] || exit 0
! grep -qw bubblewrap <<< "$*" || touch "'"$S"'/bubblewrap"
! grep -qw apparmor-profiles <<< "$*" || touch "'"$BWRAP_PROFILE_SOURCE"'"'
stub apparmor_parser 'touch "'"$S"'/loaded"'
stub apt-cache '[ ! -e "'"$S"'/no-profiles" ]'
stub bwrap 'S="'"$S"'"
[ -e "$S/bubblewrap" ] && [ ! -e "$S/bwrap-broken" ] &&
    { [ "$(cat "$S/userns")" != 1 ] || [ -e "$S/loaded" ]; }'

# Usage: reset <restricted: 0 or 1> [state file]...
reset() {
    rm -rf "$S" "$(dirname "$BWRAP_PROFILE")" "$(dirname "$BWRAP_PROFILE_SOURCE")"
    mkdir -p "$S" "$(dirname "$BWRAP_PROFILE")" "$(dirname "$BWRAP_PROFILE_SOURCE")"
    echo "$1" > "$USERNS_RESTRICT_SYSCTL"
    shift
    local f
    for f in "$@"; do
        touch "$S/$f"
    done
    : > "$STUB_LOG"
    unset DOTFILES_ASSUME_YES
}
sudo_calls() {
    grep '^sudo' "$STUB_LOG" | sed -e "s|$SANDBOX|SANDBOX|g" || true
}

# bwrap works: nothing to do
reset 1 bubblewrap loaded
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Codex's sandbox already works."
assert_eq "" "$(sudo_calls)" "sudo calls with a working bwrap"

# bwrap fails, but not because of AppArmor: the step can't fix that
reset 0 bubblewrap bwrap-broken
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "AppArmor's user namespace restriction isn't the"
assert_eq "" "$(sudo_calls)" "sudo calls with a broken bwrap"

# Restricted, and no profile anywhere: fails before asking
reset 1 bubblewrap no-profiles
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "apt doesn't offer"
assert_not_contains "$RUN_OUTPUT" "These need sudo"

# Restricted, with the profile in apparmor.d already, as 26.04's apparmor package installs it:
# it's loaded, and nothing is installed, even where apt doesn't offer apparmor-profiles. A no first.
reset 1 bubblewrap no-profiles
touch "$BWRAP_PROFILE"
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Load the bwrap-userns-restrict AppArmor profile"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_eq "" "$(sudo_calls)" "sudo calls after a no"
export DOTFILES_ASSUME_YES=1
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Codex's sandbox works now."
assert_eq "sudo apparmor_parser -r SANDBOX/apparmor.d/bwrap-userns-restrict" "$(sudo_calls)" "sudo calls to load the profile"

# No bubblewrap, restricted, and the profile already loaded, as 26.04 loads it at boot: only
# bubblewrap is installed, and the profile isn't reloaded
reset 1 loaded
touch "$BWRAP_PROFILE"
export DOTFILES_ASSUME_YES=1
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Codex's sandbox works now."
assert_eq "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y bubblewrap" "$(sudo_calls)" "sudo calls with the profile loaded at boot"

# No bubblewrap, restricted, and the profile only in apparmor-profiles: all of it is installed
reset 1
export DOTFILES_ASSUME_YES=1
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Install bubblewrap"
assert_eq "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y bubblewrap
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y apparmor-profiles apparmor-utils
sudo install -m 0644 SANDBOX/extra-profiles/bwrap-userns-restrict SANDBOX/apparmor.d/bwrap-userns-restrict
sudo apparmor_parser -r SANDBOX/apparmor.d/bwrap-userns-restrict" "$(sudo_calls)" "sudo calls for bubblewrap and the profile"

# No bubblewrap, restricted, and the profile in apparmor.d but not loaded: one run installs
# bubblewrap and loads the profile, so bwrap works
reset 1
touch "$BWRAP_PROFILE"
export DOTFILES_ASSUME_YES=1
assert_exit 0 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "Codex's sandbox works now."
assert_eq "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y bubblewrap
sudo apparmor_parser -r SANDBOX/apparmor.d/bwrap-userns-restrict" "$(sudo_calls)" "sudo calls for bubblewrap with the profile in apparmor.d"

# No bubblewrap, restricted, and no profile anywhere: bubblewrap is installed, then the step fails
reset 1 no-profiles
export DOTFILES_ASSUME_YES=1
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "apt doesn't offer"
assert_eq "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y bubblewrap" "$(sudo_calls)" "sudo calls with no profile to load"

# No bubblewrap, and no restriction: only bubblewrap
reset 0
export DOTFILES_ASSUME_YES=1
assert_exit 0 setup_codex_sandbox
assert_eq "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y bubblewrap" "$(sudo_calls)" "sudo calls for bubblewrap alone"

# bwrap fails after installing bubblewrap, and not because of AppArmor: the step fails
reset 0 bwrap-broken
export DOTFILES_ASSUME_YES=1
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "AppArmor's user namespace restriction isn't the"

# bwrap still fails after loading the profile: the step fails
reset 1 bwrap-broken
touch "$BWRAP_PROFILE"
export DOTFILES_ASSUME_YES=1
assert_exit 1 setup_codex_sandbox
assert_contains "$RUN_OUTPUT" "bwrap still can't create a sandbox"
assert_contains "$(sudo_calls)" "sudo apparmor_parser -r"

# bwrap_works, which status reports, runs bwrap
reset 1 bubblewrap
assert_exit 1 bwrap_works
touch "$S/loaded"
assert_exit 0 bwrap_works
test_done
