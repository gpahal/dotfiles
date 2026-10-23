#!/bin/bash
# shellcheck disable=SC2329 # the step calls the functions this test replaces

# The docker step's daemon.json merge: your settings kept, and the old file back when Docker
# rejects the new one.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=docker-fixture.sh
source "$TESTS_DIR/docker-fixture.sh"

command -v jq &>/dev/null || skip "jq isn't installed"
load_script docker/install.sh
as_os ubuntu
docker_sandbox_paths
stub_sudo_exec
stub systemctl
stub dockerd
SETTINGS='"log-driver": "local", "live-restore": true, "ip": "127.0.0.1",
    "default-network-opts": {"bridge": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}},
    "default-address-pools": [
        {"base": "172.17.0.0/16", "size": 24}, {"base": "172.18.0.0/15", "size": 24},
        {"base": "172.20.0.0/14", "size": 24}, {"base": "172.24.0.0/13", "size": 24}]'
sorted() {
    jq -S -c . "${1:-$DOCKER_DAEMON_CONFIG}"
}

assert_exit 0 configure_daemon
assert_eq "$(sorted /dev/stdin <<< "{$SETTINGS}")" "$(sorted)" "a new daemon.json"
assert_eq 644 "$(file_mode "$DOCKER_DAEMON_CONFIG")" "mode of a new daemon.json"
assert_file_contains "$STUB_LOG" "systemctl try-restart docker.service"
assert_exit 0 daemon_configured

: > "$STUB_LOG"
before="$(/bin/ls -li "$DOCKER_DAEMON_CONFIG")"
assert_exit 0 configure_daemon
assert_contains "$RUN_OUTPUT" "already sets log-driver, live-restore, localhost-only published ports, and address pools"
assert_eq "$before" "$(/bin/ls -li "$DOCKER_DAEMON_CONFIG")" "daemon.json after a re-run"
assert_file_not_contains "$STUB_LOG" "systemctl"

# Driver-specific log-opts don't survive the switch to local
printf '%s\n' '{"log-driver":"syslog","log-opts":{"syslog-address":"udp://127.0.0.1:514","max-size":"10m"},"dns":["1.1.1.1"]}' > "$DOCKER_DAEMON_CONFIG"
assert_exit 0 configure_daemon
assert_eq null "$(jq -r '.["log-opts"]["syslog-address"]' "$DOCKER_DAEMON_CONFIG")" "incompatible option removed"
assert_eq 10m "$(jq -r '.["log-opts"]["max-size"]' "$DOCKER_DAEMON_CONFIG")" "compatible limit kept"
assert_file_contains "$STUB_LOG" 'dockerd --validate --config-file'
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a change"

printf '{"log-driver":"json-file","unknown-option":true}\n' > "$DOCKER_DAEMON_CONFIG"
snapshot "$DOCKER_DAEMON_CONFIG"
stub dockerd 'exit 1'
assert_exit 1 configure_daemon
assert_unchanged "$DOCKER_DAEMON_CONFIG" "after a failed validation"
assert_file_not_contains "$STUB_LOG" 'try-restart'
stub dockerd

printf '{"log-driver":"json-file"}\n' > "$DOCKER_DAEMON_CONFIG"
snapshot "$DOCKER_DAEMON_CONFIG"
stub systemctl '[ "$1" != try-restart ] || exit 1'
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "Docker activation failed; restored the previous configuration."
assert_unchanged "$DOCKER_DAEMON_CONFIG" "after a failed restart"
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a failed restart"
wrap_fn write_root_file 'return 1'
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "putting the previous configuration back failed too"
assert_contains "$RUN_OUTPUT" '{"log-driver":"json-file"}'
restore_fn write_root_file
printf '{"log-driver":"json-file"}\n' > "$DOCKER_DAEMON_CONFIG"
stub systemctl
assert_exit 0 configure_daemon
assert_file_contains "$STUB_LOG" 'systemctl try-restart docker.service'
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a retry"

echo '{"dns": ["1.1.1.1"], "log-driver": "json-file", "ip": "0.0.0.0", "default-address-pools": [{"base":"172.17.0.0/16","size":16}]}' > "$DOCKER_DAEMON_CONFIG"
chmod 640 "$DOCKER_DAEMON_CONFIG"
assert_exit 1 daemon_configured
assert_exit 0 configure_daemon
merged='{"dns": ["1.1.1.1"], '"$SETTINGS}"
assert_eq "$(sorted /dev/stdin <<< "$merged")" "$(sorted)" "a merged daemon.json"
assert_eq 640 "$(file_mode "$DOCKER_DAEMON_CONFIG")" "mode of a merged daemon.json"

: > "$DOCKER_DAEMON_CONFIG"
assert_exit 0 configure_daemon
assert_eq "$(sorted /dev/stdin <<< "{$SETTINGS}")" "$(sorted)" "daemon.json from an empty file"

echo '{"dns": [' > "$DOCKER_DAEMON_CONFIG"
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "isn't one valid JSON object"
assert_eq '{"dns": [' "$(cat "$DOCKER_DAEMON_CONFIG")" "invalid daemon.json"
assert_file_not_contains "$STUB_LOG" "systemctl"
{ echo '{"debug": true}'; echo "{$SETTINGS}"; } > "$DOCKER_DAEMON_CONFIG"
snapshot "$DOCKER_DAEMON_CONFIG"
assert_exit 1 daemon_configured
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "isn't one valid JSON object"
assert_unchanged "$DOCKER_DAEMON_CONFIG" "with two JSON values"
assert_file_not_contains "$STUB_LOG" "dockerd"
test_done
