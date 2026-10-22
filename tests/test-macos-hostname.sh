#!/bin/bash
set -euo pipefail

# Ghostty drops an OSC 7 report whose host has characters a URL can't hold.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script macos/install.sh
as_os macos
replace_fn each_default
replace_fn hotkey_off 'return 0'
replace_fn status_filevault
replace_fn firewall_on 'return 0'
replace_fn stealth_mode_on 'return 0'
replace_fn app_store_auto_updates 'return 0'

stub scutil 'case "$1 $2" in
    "--get HostName") [ -n "${HOST_NAME:-}" ] && echo "$HOST_NAME" ;;
    "--get LocalHostName") echo Garvits-MacBook-Pro ;;
    *) exit 1 ;;
esac'
stub sudo

export HOST_NAME=Garvits-MacBook-Pro.local
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "hostname"
assert_not_contains "$(cat "$STUB_LOG")" "sudo"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Hostname set"

answer yes
for HOST_NAME in "" "Unknown_d6:96:0e:05:c6:0a"; do
    export HOST_NAME
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Hostname set"
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Set the hostname to Garvits-MacBook-Pro."
    assert_file_contains "$STUB_LOG" "sudo scutil --set HostName Garvits-MacBook-Pro"
done

answer no
export HOST_NAME=""
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged."
assert_not_contains "$(cat "$STUB_LOG")" "sudo"

stub sudo 'exit 1'
answer yes
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't set the hostname."
test_done
