#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions

# unattended-upgrades in the ubuntu step: a later file turning it off, merging 20auto-upgrades while
# keeping your keys, and a 20auto-upgrades only root can read.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up

echo 'APT::Periodic::Unattended-Upgrade "0";' > "$SANDBOX/apt.conf.d/99off"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "effective periodic settings still disable daily updates"
rm "$SANDBOX/apt.conf.d/99off"

# Software & Updates writes other APT::Periodic keys into 20auto-upgrades; keep them
printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Download-Upgradeable-Packages "1";' \
    'APT::Periodic::AutocleanInterval "7";' 'APT::Periodic::Unattended-Upgrade "0";' > "$AUTO_UPGRADES_CONF"
run main
assert_eq 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Enable "1";' "$(cat "$AUTO_UPGRADES_CONF")" "20auto-upgrades after the merge"
run main
assert_file_not_contains "$STUB_LOG" "tee $AUTO_UPGRADES_CONF"

# APT takes several statements on a line; only ours are replaced, the rest kept in order
assert_eq 'APT::Periodic::Enable "1"; APT::Periodic::AutocleanInterval "7";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' \
    "$(merged_auto_upgrades 'APT::Periodic::Enable "0"; APT::Periodic::AutocleanInterval "7";')" \
    "a line with our key first"
assert_eq '  APT::Periodic::AutocleanInterval "7";  APT::Periodic::Update-Package-Lists "1"; // ours
Foo::Note "a; b"; APT::Periodic::Unattended-Upgrade "1";
Foo::One "1"; Foo::Two "2";
APT::Periodic::Enable "1";' \
    "$(merged_auto_upgrades '  APT::Periodic::AutocleanInterval "7";  apt::periodic::update-package-lists "0"; // ours
Foo::Note "a; b"; APT::Periodic::Unattended-Upgrade "0";
Foo::One "1"; Foo::Two "2";')" \
    "lines with our key second, a ; in quotes, and no key of ours"
# A line it can't split stays, and ours follow it, since it could set or clear them
assert_eq 'APT::Periodic::Enable "1";
APT::Periodic { Enable "0"; };
/* APT::Periodic::Update-Package-Lists "0"; */
# APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' \
    "$(merged_auto_upgrades 'APT::Periodic::Enable "0";
APT::Periodic { Enable "0"; };
/* APT::Periodic::Update-Package-Lists "0"; */
# APT::Periodic::Unattended-Upgrade "0";')" \
    "a scope and comments"
assert_eq 'APT::Periodic::Enable
    "0";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";' \
    "$(merged_auto_upgrades 'APT::Periodic::Enable
    "0";
APT::Periodic::Unattended-Upgrade "0";')" \
    "a statement over two lines"

# Only root can read 20auto-upgrades, so apt-config skips it. The sudo stub makes it readable while it runs.
stub sudo '[ "${1:-}" != -n ] || { [ -e "$SANDBOX/cached" ] || exit 1; shift; }
f="'"$AUTO_UPGRADES_CONF"'"
[ ! -e "$SANDBOX/sudo-cat-fails" ] || [ "$*" != "cat $f" ] || exit 1
hidden=false
if [ -e "$f" ] && [ ! -r "$f" ]; then chmod u+r "$f"; hidden=true; fi
status=0
env "$@" || status=$?
! "$hidden" || chmod u-r "$f"
exit "$status"'
printf '%s\n' 'APT::Periodic::AutocleanInterval "7";' 'APT::Periodic::Unattended-Upgrade "0";' > "$AUTO_UPGRADES_CONF"
chmod 200 "$AUTO_UPGRADES_CONF"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified unattended-upgrades runs daily (only root can read $AUTO_UPGRADES_CONF"
# A re-run with nothing else to change doesn't ask for sudo only to read it
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_contains "$RUN_OUTPUT" "Only root can read $AUTO_UPGRADES_CONF; run sudo -v"
assert_file_not_contains "$STUB_LOG" "sudo cat"
# With another change pending, reading it joins the sudo list; a failed read writes nothing
rm "$SANDBOX/locale"
touch "$SANDBOX/sudo-cat-fails"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Check unattended-upgrades' settings in $AUTO_UPGRADES_CONF"
rm "$SANDBOX/sudo-cat-fails"
chmod 600 "$AUTO_UPGRADES_CONF"
assert_eq 'APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "0";' "$(cat "$AUTO_UPGRADES_CONF")" "the unreadable 20auto-upgrades after a failed read"
chmod 200 "$AUTO_UPGRADES_CONF"
rm -f "$SANDBOX/locale"
assert_exit 0 main
chmod 600 "$AUTO_UPGRADES_CONF"
assert_eq 'APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";' "$(cat "$AUTO_UPGRADES_CONF")" "the unreadable 20auto-upgrades after the merge"
chmod 200 "$AUTO_UPGRADES_CONF"
touch "$SANDBOX/cached"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         unattended-upgrades runs daily"
chmod 600 "$AUTO_UPGRADES_CONF"

test_done
