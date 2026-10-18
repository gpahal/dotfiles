#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The macos step sets HostName to LocalHostName when it's unset or has characters a URL can't
# hold, after asking, since Ghostty drops an OSC 7 folder report whose host is such a name. A
# declined prompt leaves it and doesn't fail the step. Its status reports the hostname.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script macos/install.sh
is_macos() { true; }
# Only the hostname: the rest of the step is covered elsewhere
each_default() { true; }
hotkey_off() { true; }
status_filevault() { true; }
status_app_firewall() { true; }

# HOST_NAME is HostName, unset when empty
# shellcheck disable=SC2016 # stub bodies, expanded when they run
stub scutil 'case "$1 $2" in
    "--get HostName") [ -n "${HOST_NAME:-}" ] && echo "$HOST_NAME" ;;
    "--get LocalHostName") echo Garvits-MacBook-Pro ;;
    *) exit 1 ;;
esac'
stub sudo

# Already set: nothing changes
export HOST_NAME=Garvits-MacBook-Pro.local
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The hostname is already Garvits-MacBook-Pro.local."
assert_not_contains "$(cat "$STUB_LOG")" "sudo"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Hostname set"

# Unset or invalid: status reports it, and the step sets it after asking
for HOST_NAME in "" "Unknown_d6:96:0e:05:c6:0a"; do
    export HOST_NAME
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Hostname set"
    : > "$STUB_LOG"
    DOTFILES_ASSUME_YES=1 assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Set the hostname to Garvits-MacBook-Pro."
    assert_file_contains "$STUB_LOG" "sudo scutil --set HostName Garvits-MacBook-Pro"
done

# Declined: left unset, and the step still succeeds
export HOST_NAME=""
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged."
assert_not_contains "$(cat "$STUB_LOG")" "sudo"

# A failed set fails the step
stub sudo 'exit 1'
DOTFILES_ASSUME_YES=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't set the hostname."
test_done
