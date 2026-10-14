#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The ubuntu step's warning about Wi-Fi that connects only after login: a connection limited to a
# user, or whose password NetworkManager doesn't keep for the system (psk-flags agent-owned or
# not-saved, bits 1 and 2). nmcli is a stub.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ubuntu/install.sh

# One active system-wide Wi-Fi connection (empty permissions) whose psk-flags nmcli prints from
# $SANDBOX/flags
stub nmcli 'case "$*" in
    "-t -f UUID,TYPE,NAME connection show --active") echo "4444-dddd:802-11-wireless:Office" ;;
    "-g connection.permissions connection show uuid 4444-dddd") echo "" ;;
    "-g 802-11-wireless-security.psk-flags connection show uuid 4444-dddd") cat "'"$SANDBOX"'/flags" ;;
esac'

for flags in "1 (agent-owned)" "2 (not-saved)" "3 (agent-owned, not-saved)"; do
    echo "$flags" > "$SANDBOX/flags"
    run warn_wifi_needs_login
    assert_contains "$RUN_OUTPUT" 'Wi-Fi "Office" only connects after you log in'
    assert_contains "$RUN_OUTPUT" 'sudo nmcli --ask connection up uuid 4444-dddd'
done

# A password the system keeps, one not needed, or no flags at all (an open network)
for flags in "0 (none)" "4 (not-required)" ""; do
    echo "$flags" > "$SANDBOX/flags"
    run warn_wifi_needs_login
    assert_eq "" "$RUN_OUTPUT" "the warning for psk-flags \"$flags\""
done
test_done
