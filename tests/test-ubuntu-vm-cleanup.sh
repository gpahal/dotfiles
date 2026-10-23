#!/bin/bash

# scripts/test-ubuntu.sh deletes only a machine it created, including when signaled.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# orb create makes the machine before failing with create-fails, as when another run made it
stub orb 'case "$1" in
    list) [ ! -e "$SANDBOX/exists" ] || echo dotfiles-test ;;
    create)
        touch "$SANDBOX/exists"
        [ ! -e "$SANDBOX/create-fails" ] || exit 1 ;;
    run) kill -s "$(cat "$SANDBOX/signal")" "$PPID" ;;
esac'
run_script() {
    assert_exit "$1" "$BASH" "$REPO_DIR/scripts/test-ubuntu.sh"
}

touch "$SANDBOX/exists"
run_script 1
assert_contains "$RUN_OUTPUT" "already exists"
assert_file_not_contains "$STUB_LOG" "orb delete"

rm "$SANDBOX/exists"
touch "$SANDBOX/create-fails"
run_script 1
assert_contains "$RUN_OUTPUT" "Couldn't create the machine"
assert_file_not_contains "$STUB_LOG" "orb delete"
rm "$SANDBOX/exists" "$SANDBOX/create-fails"

for signal in TERM:143 INT:130; do
    echo "${signal%:*}" > "$SANDBOX/signal"
    run_script "${signal#*:}"
    assert_file_contains "$STUB_LOG" "orb delete -f dotfiles-test"
    rm -f "$SANDBOX/exists"
done

test_done
