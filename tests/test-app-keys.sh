#!/bin/bash

# ai_tools/lib/app-keys.sh: the --status check that an installed app still has the settings keys a
# step sets, which stands in for naming the app version the keys were checked against.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script lib/common.sh
# shellcheck source=../ai_tools/lib/app-keys.sh
source "$REPO_DIR/ai_tools/lib/app-keys.sh"

# --- jq_filter_keys: every .name, once, dashes and brackets aside ---
assert_eq "accelerator
menuBarEnabled
preferences" "$(jq_filter_keys '.preferences.menuBarEnabled = false
    | .preferences.quickEntryShortcut |= 1 | .preferences.menuBarEnabled = true | .accelerator = 1' |
    grep -v quickEntryShortcut)" "keys from a filter"

BUNDLE="$SANDBOX/app.asar"
# Binary around the keys, as in a real app.asar
printf 'x\0\001ccKeepAwake:true,menuBarEnabled\0\377y' > "$BUNDLE"

assert_exit 0 status_app_keys "App keys" "$BUNDLE" ccKeepAwake menuBarEnabled
assert_eq "  ok         App keys" "$RUN_OUTPUT" "every key present"

assert_exit 0 status_app_keys "App keys" "$BUNDLE" ccKeepAwake renamedKey otherKey
assert_contains "$RUN_OUTPUT" "missing    App keys: the installed app lacks renamedKey otherKey;"

# A key that's only part of a longer one still counts: keys are matched as text, not tokens
assert_exit 0 status_app_keys "App keys" "$BUNDLE" ccKeep
assert_contains "$RUN_OUTPUT" "ok         App keys"

# No app: the app's own item reports it, so this doesn't need attention
assert_exit 0 status_app_keys "App keys" "$SANDBOX/none.asar" ccKeepAwake
assert_contains "$RUN_OUTPUT" "unverified App keys: couldn't find the installed app's app.asar"
assert_exit 0 status_app_keys "App keys" "" ccKeepAwake
assert_contains "$RUN_OUTPUT" "unverified"

# A search that finds the made-up key can't tell a missing key
printf '%s\n' ccKeepAwake "$APP_KEYS_MADE_UP" > "$SANDBOX/odd.asar"
assert_exit 0 status_app_keys "App keys" "$SANDBOX/odd.asar" ccKeepAwake
assert_contains "$RUN_OUTPUT" "unknown    App keys: the search for keys"

# Health alerts skip it
export DOTFILES_STATUS_FOR_ALERTS=1
assert_exit 0 status_app_keys "App keys" "$BUNDLE" renamedKey
assert_eq "" "$RUN_OUTPUT" "output under status_for_alerts"
unset DOTFILES_STATUS_FOR_ALERTS

# deb_bundle: the package's app.asar, not a file inside app.asar.unpacked
stub dpkg-query '[ "$*" == "-L t3code" ] && printf "%s\n" /opt/T3 "/opt/T3/resources/app.asar.unpacked/x" "/opt/T3/resources/app.asar"'
assert_eq "/opt/T3/resources/app.asar" "$(deb_bundle t3code)" "the deb's app.asar"
assert_eq "" "$(deb_bundle other || true)" "a package with no app.asar"

test_done
