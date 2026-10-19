#!/bin/bash
set -euo pipefail

# scripts/test-ubuntu.sh, with OrbStack stubbed, deletes only a machine it created: not one that
# already exists, nor one another run made while this one's orb create failed. A SIGTERM stops it
# with 143 and a SIGINT with 130, and either way the machine it created is deleted.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# orb list -q names the machine once $SANDBOX/exists does. orb create makes it, or fails when
# $SANDBOX/create-fails says so, after another run made it. orb run sends the script the signal in
# $SANDBOX/signal, as Ctrl-C or a kill would.
stub orb 'case "$1" in
    list) [ ! -e "'"$SANDBOX"'/exists" ] || echo dotfiles-test ;;
    create)
        touch "'"$SANDBOX"'/exists"
        [ ! -e "'"$SANDBOX"'/create-fails" ] || exit 1 ;;
    run) kill -s "$(cat "'"$SANDBOX"'/signal")" "$PPID" ;;
esac'
run_script() {
    : > "$STUB_LOG"
    assert_exit "$1" "$BASH" "$REPO_DIR/scripts/test-ubuntu.sh"
}

# A machine that already exists is left alone
touch "$SANDBOX/exists"
run_script 1
assert_contains "$RUN_OUTPUT" "already exists"
assert_file_not_contains "$STUB_LOG" "orb delete"

# Another run makes the machine while this one creates it: this one's create fails, and it
# deletes nothing
rm "$SANDBOX/exists"
touch "$SANDBOX/create-fails"
run_script 1
assert_contains "$RUN_OUTPUT" "Couldn't create the machine"
assert_file_not_contains "$STUB_LOG" "orb delete"
rm "$SANDBOX/exists" "$SANDBOX/create-fails"

# Stopped once its machine exists, it exits as the signal says and deletes the machine
for signal in TERM:143 INT:130; do
    echo "${signal%:*}" > "$SANDBOX/signal"
    run_script "${signal#*:}"
    assert_file_contains "$STUB_LOG" "orb delete -f dotfiles-test"
    rm -f "$SANDBOX/exists"
done

test_done
