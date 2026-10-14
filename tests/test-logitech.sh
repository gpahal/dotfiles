#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The logitech step skips on macOS, and on Ubuntu installs Solaar from Ubuntu's archive and on a
# re-run changes nothing. A failed install fails the step.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script logitech/install.sh
stub sudo 'exec env "$@"'

# macOS: nothing to do
is_macos() { true; }
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "installs Logi Options+ on macOS; skipping"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    Solaar"
assert_eq "" "$(cat "$STUB_LOG")" "commands run on macOS"

is_macos() { false; }
is_ubuntu() { true; }
# Solaar is installed when $SANDBOX/solaar exists
stub dpkg-query '[ "${!#}" != solaar ] || [ ! -e "'"$SANDBOX"'/solaar" ] || echo "install ok installed"'
stub apt-get 'case "$*" in
    *"install -y solaar") [ ! -e "'"$SANDBOX"'/install-fails" ] || exit 100; touch "'"$SANDBOX"'/solaar" ;;
esac'

# Declined: nothing changes
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Solaar"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install Solaar from Ubuntu's universe"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_eq "" "$(grep -v '^dpkg-query' "$STUB_LOG" || true)" "commands run after a no"

# A failed install fails the step
export DOTFILES_ASSUME_YES=1
touch "$SANDBOX/install-fails"
assert_exit 1 main
rm "$SANDBOX/install-fails"

# Approved: Solaar comes from the archive, with no source added
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Applied. Solaar starts with your desktop session."
assert_eq "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y solaar
apt-get -o DPkg::Lock::Timeout=300 install -y solaar" "$(grep -v '^dpkg-query' "$STUB_LOG")" "commands run to install Solaar"
assert_eq "" "$(ls "$APT_SOURCES_DIR")" "apt sources after the install"
assert_exit 0 status

# Re-run: nothing to do, and no sudo
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Solaar is already installed."
assert_file_not_contains "$STUB_LOG" "sudo"

# Only the stubs ran, never a real apt-get
assert_eq "" "$(cat "$SANDBOX/unstubbed.log" 2> /dev/null || true)" "unstubbed commands"
test_done
