#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions

# The ubuntu step's Tailscale on a set-up machine: its first login, what operator mode exposes, and
# its apt source.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up

# tailscale up resets auto-update and operator, so the step waits for the first login
touch "$SANDBOX/tailscale-reset"
echo NeedsLogin > "$SANDBOX/tailscale-state"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Tailscale auto-updates, with $(id -un) as its operator"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Turn on Tailscale's auto-update"
assert_contains "$RUN_OUTPUT" "Run sudo tailscale up, then bash setup.sh ubuntu"
assert_file_not_contains "$STUB_LOG" "tailscale set"
echo Running > "$SANDBOX/tailscale-state"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turn on Tailscale's auto-update and make $(id -un) its operator"
assert_file_contains "$STUB_LOG" "sudo tailscale set --auto-update --operator=$(id -un)"
rm "$SANDBOX/tailscale-reset"

# Operator mode lets anything running as you publish a funnel or turn on Tailscale SSH
run status_tailscale_exposure
assert_contains "$RUN_OUTPUT" "ok         No Tailscale funnel publishing a port to the internet"
assert_contains "$RUN_OUTPUT" "ok         Tailscale SSH off"
echo '{"AllowFunnel": {"m.ts.net:443": true, "m.ts.net:10000": false}, "Foreground": {"s": {"AllowFunnel": {"m.ts.net:8443": true}}}}' \
    > "$SANDBOX/tailscale-serve"
touch "$SANDBOX/tailscale-ssh"
run status_tailscale_exposure
assert_contains "$RUN_OUTPUT" "missing    No Tailscale funnel publishing a port to the internet: m.ts.net:443, m.ts.net:8443 is published"
assert_contains "$RUN_OUTPUT" "missing    Tailscale SSH off"
rm "$SANDBOX/tailscale-serve" "$SANDBOX/tailscale-ssh"

# Tailscale's apt source; test-apt-sources.sh covers its states
mkdir -p "$(dirname "$TAILSCALE_KEYRING")"
stub_fetch
stub_gpg_fpr "$TAILSCALE_KEY_FPR"
stub_http_status

# Subshell: hide changes PATH for the rest of the test
failures="$TEST_FAILURES"
rm "$TAILSCALE_LIST"
(
    cp "$STUB_DIR/tailscale" "$SANDBOX/tailscale-stub"
    hide tailscale
    stub apt-get 'case "$*" in
        *"install -y tailscale") cp "$SANDBOX/tailscale-stub" "$STUB_DIR/tailscale" ;;
        *) cat "$SANDBOX/apt-upgrade" 2> /dev/null || true ;;
    esac'
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Tailscale"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Install Tailscale from its apt repo: write $TAILSCALE_LIST and its key"
    assert_eq "$TAILSCALE_ENTRY" "$(cat "$TAILSCALE_LIST")" "Tailscale's source after installing it"
    assert_eq "update --error-on=any
install -y tailscale" "$(grep -oE '^apt-get -o DPkg::Lock::Timeout=300 (update --error-on=any|install -y tailscale)' "$STUB_LOG" |
        sed 's/^apt-get -o DPkg::Lock::Timeout=300 //')" "apt-get's runs to install Tailscale"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"
    [ "$TEST_FAILURES" -eq "$failures" ]
) || fail "installing Tailscale"
test_done
