#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The logitech step installs Solaar from apt on Ubuntu. Stubs stand in for dpkg-query, whose answer
# depends on $SANDBOX/solaar, apt-get, which creates it, and sudo.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script logitech/install.sh
export SANDBOX
stub dpkg-query '[ "${*: -1}" == solaar ] && [ -e "$SANDBOX/solaar" ] && printf "install ok installed"'
stub apt-get '[ -z "${APT_FAILS:-}" ] || exit 100
[ -z "${UPDATE_FAILS:-}" ] || [ "${*: -1}" != update ] || exit 100
[ "${*: -1}" != solaar ] || touch "$SANDBOX/solaar"'
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0
stub_sudo_exec

as_os ubuntu

# Not installed: status says so
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Solaar"

# Without a terminal, confirm declines: listed, left uninstalled, and the step passes
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install Solaar"
assert_file_not_contains "$STUB_LOG" "apt-get"
[ ! -e "$SANDBOX/solaar" ] || fail "Solaar was installed though confirm declined"

# A failed install fails the step
export DOTFILES_ASSUME_YES=1 APT_FAILS=1
assert_exit 1 main
[ ! -e "$SANDBOX/solaar" ] || fail "Solaar counts as installed after a failed install"

# A failed update of apt's lists fails the step before the install
export APT_FAILS="" UPDATE_FAILS=1
: > "$STUB_LOG"
assert_exit 1 main
assert_file_not_contains "$STUB_LOG" "install -y solaar"
export UPDATE_FAILS=""

# Approved: apt-get updates its lists, then installs it with sudo, and status reports it
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get"
assert_eq "update" "$(grep -E '^sudo .*apt-get' "$STUB_LOG" | head -n 1 | awk '{ print $NF }')" "apt-get's first run"
assert_file_contains "$STUB_LOG" "install -y solaar"
[ -e "$SANDBOX/solaar" ] || fail "Solaar wasn't installed"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Solaar"

# Re-run: already installed, so nothing runs with sudo
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already installed"
assert_file_not_contains "$STUB_LOG" "sudo"
test_done
