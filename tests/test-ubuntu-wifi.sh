#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# os: ubuntu

# The ubuntu step's warning about Wi-Fi that connects only after login: a connection limited to a
# user, or whose password NetworkManager doesn't keep for the system (psk-flags agent-owned or
# not-saved, bits 1 and 2), named by UUID and shown whole, which nmcli -e no leaves unescaped. nmcli
# is a stub.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ubuntu/install.sh

# One active system-wide Wi-Fi connection (empty permissions) whose psk-flags nmcli prints from
# $SANDBOX/flags
stub nmcli 'case "$*" in
    "-t -e no -f UUID,TYPE,NAME connection show --active") echo "4444-dddd:802-11-wireless:Office" ;;
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

# A name with a colon or a backslash is read whole, and the commands name the connection by UUID
stub nmcli 'case "$*" in
    "-t -e no -f UUID,TYPE,NAME connection show --active") printf "%s\n" "1111-aaaa:802-3-ethernet:Wired" \
        "2222-bbbb:802-11-wireless:Home:5G" "3333-cccc:802-11-wireless:Back\\slash" ;;
    "-g connection.permissions connection show uuid 2222-bbbb") echo "user:me" ;;
    "-g 802-11-wireless-security.psk-flags connection show uuid 3333-cccc") echo "1 (agent-owned)" ;;
esac'
run warn_wifi_needs_login
assert_contains "$RUN_OUTPUT" 'Wi-Fi "Home:5G" only connects after you log in'
assert_contains "$RUN_OUTPUT" 'sudo nmcli --ask connection up uuid 2222-bbbb'
assert_contains "$RUN_OUTPUT" 'sudo nmcli connection modify uuid 2222-bbbb connection.permissions'
assert_contains "$RUN_OUTPUT" 'Wi-Fi "Back\slash" only connects after you log in'
assert_contains "$RUN_OUTPUT" 'sudo nmcli --ask connection up uuid 3333-cccc'
assert_not_contains "$RUN_OUTPUT" "Wired"
test_done
