#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The docker step merges log-driver, live-restore, 127.0.0.1 as the address published ports bind to,
# and address pools that keep Docker's networks in 172.16.0.0/12 into /etc/docker/daemon.json,
# keeping the file's other keys and mode, restarts a running daemon only when the file changed, and
# leaves invalid JSON alone. A file of several JSON values isn't configured. A failed write leaves
# the old file whole, and a failed restart puts it back and keeps a backup, which goes once Docker
# takes the new file.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script docker/install.sh
is_macos() { false; }
is_ubuntu() { true; }
stub_sudo_exec
stub systemctl
stub dockerd
DOCKER_DAEMON_CONFIG="$SANDBOX/etc/docker/daemon.json"
SETTINGS='"log-driver": "local", "live-restore": true, "ip": "127.0.0.1",
    "default-network-opts": {"bridge": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}},
    "default-address-pools": [
        {"base": "172.17.0.0/16", "size": 24}, {"base": "172.18.0.0/15", "size": 24},
        {"base": "172.20.0.0/14", "size": 24}, {"base": "172.24.0.0/13", "size": 24}]'
# Compact, with sorted keys, to compare with the expected JSON. Reads daemon.json, or the file
# given.
sorted() {
    jq -S -c . "${1:-$DOCKER_DAEMON_CONFIG}"
}

# No file: it's created, world-readable, and the daemon restarted if it runs
assert_exit 0 configure_daemon
assert_eq "$(sorted /dev/stdin <<< "{$SETTINGS}")" "$(sorted)" "a new daemon.json"
assert_eq "-rw-r--r--" "$(/bin/ls -l "$DOCKER_DAEMON_CONFIG" | cut -c1-10)" "mode of a new daemon.json"
assert_file_contains "$STUB_LOG" "systemctl try-restart docker.service"
assert_exit 0 daemon_configured

# Already set: nothing written or restarted
: > "$STUB_LOG"
before="$(/bin/ls -li "$DOCKER_DAEMON_CONFIG")"
assert_exit 0 configure_daemon
assert_contains "$RUN_OUTPUT" "already sets log-driver, live-restore, localhost-only published ports, and address pools"
assert_eq "$before" "$(/bin/ls -li "$DOCKER_DAEMON_CONFIG")" "daemon.json after a re-run"
assert_file_not_contains "$STUB_LOG" "systemctl"

# The 15 /16 pools of an earlier run need the change to /24s
jq -c '.["default-address-pools"] = [range(17; 32) | {base: "172.\(.).0.0/16", size: 16}]' \
    "$DOCKER_DAEMON_CONFIG" > "$SANDBOX/old-pools.json"
cp "$SANDBOX/old-pools.json" "$DOCKER_DAEMON_CONFIG"
assert_exit 1 daemon_configured
assert_exit 0 configure_daemon
assert_eq "$(sorted /dev/stdin <<< "{$SETTINGS}")" "$(sorted)" "daemon.json after the change to /24 pools"

# Driver-specific options don't survive the switch to local; compatible limits and other
# daemon settings do. No temp file is left beside it.
printf '%s\n' '{"log-driver":"syslog","log-opts":{"syslog-address":"udp://127.0.0.1:514","max-size":"10m"},"dns":["1.1.1.1"]}' > "$DOCKER_DAEMON_CONFIG"
assert_exit 0 configure_daemon
assert_eq null "$(jq -r '.["log-opts"]["syslog-address"]' "$DOCKER_DAEMON_CONFIG")" "incompatible option removed"
assert_eq 10m "$(jq -r '.["log-opts"]["max-size"]' "$DOCKER_DAEMON_CONFIG")" "compatible limit kept"
assert_file_contains "$STUB_LOG" 'dockerd --validate --config-file'
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a change"

# A failed write leaves the original whole, with no backup or temp file, and Docker isn't restarted
printf '{"log-driver":"json-file"}\n' > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-write"
stub mv '[ "${!#}" != "'"$DOCKER_DAEMON_CONFIG"'" ] || exit 1
exec /bin/mv "$@"'
: > "$STUB_LOG"
assert_exit 1 configure_daemon
rm "$STUB_DIR/mv"
assert_exit 0 cmp -s "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-write"
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a failed write"
assert_file_not_contains "$STUB_LOG" 'try-restart'

# Invalid proposed settings leave the original untouched and never restart Docker.
printf '{"log-driver":"json-file","unknown-option":true}\n' > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-validation"
stub dockerd 'exit 1'
: > "$STUB_LOG"
assert_exit 1 configure_daemon
assert_exit 0 cmp -s "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-validation"
assert_file_not_contains "$STUB_LOG" 'try-restart'
stub dockerd

# Failed activation puts the original back, from memory, so no backup is left in /etc/docker, and
# the next run retries rather than claiming done
printf '{"log-driver":"json-file"}\n' > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-restart"
stub systemctl '[ "$1" != try-restart ] || exit 1'
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "Docker activation failed; restored the previous configuration."
assert_exit 0 cmp -s "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-restart"
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a failed restart"
# When it can't go back either, the step prints it, to write back by hand
eval "real_$(declare -f write_root_file)"
write_root_file() { return 1; }
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "putting the previous configuration back failed too"
assert_contains "$RUN_OUTPUT" '{"log-driver":"json-file"}'
eval "$(declare -f real_write_root_file | sed '1s/real_//')"
cp "$SANDBOX/before-restart" "$DOCKER_DAEMON_CONFIG"
stub systemctl
: > "$STUB_LOG"
assert_exit 0 configure_daemon
assert_file_contains "$STUB_LOG" 'systemctl try-restart docker.service'
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a retry"

# Other keys are kept, a setting with another value is replaced, and the file keeps its mode
echo '{"dns": ["1.1.1.1"], "log-driver": "json-file", "ip": "0.0.0.0"}' > "$DOCKER_DAEMON_CONFIG"
chmod 640 "$DOCKER_DAEMON_CONFIG"
assert_exit 1 daemon_configured
assert_exit 0 configure_daemon
merged='{"dns": ["1.1.1.1"], '"$SETTINGS}"
assert_eq "$(sorted /dev/stdin <<< "$merged")" "$(sorted)" "a merged daemon.json"
assert_eq "-rw-r-----" "$(/bin/ls -l "$DOCKER_DAEMON_CONFIG" | cut -c1-10)" "mode of a merged daemon.json"

# An empty file counts as {}
: > "$DOCKER_DAEMON_CONFIG"
assert_exit 0 configure_daemon
assert_eq "$(sorted /dev/stdin <<< "{$SETTINGS}")" "$(sorted)" "daemon.json from an empty file"

# Invalid JSON: left as it is, and the step fails
echo '{"dns": [' > "$DOCKER_DAEMON_CONFIG"
: > "$STUB_LOG"
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "isn't one valid JSON object"
assert_eq '{"dns": [' "$(cat "$DOCKER_DAEMON_CONFIG")" "invalid daemon.json"
assert_file_not_contains "$STUB_LOG" "systemctl"
# So is a file with two JSON values, which jq would turn into two
printf '%s\n' '{"dns": ["1.1.1.1"]}' '{"debug": true}' > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$SANDBOX/two-values"
: > "$STUB_LOG"
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "isn't one valid JSON object"
assert_exit 0 cmp -s "$DOCKER_DAEMON_CONFIG" "$SANDBOX/two-values"
assert_file_not_contains "$STUB_LOG" "dockerd"
assert_file_not_contains "$STUB_LOG" "systemctl"
# Even when the last of them has every setting: it's not configured, and the step leaves it alone
{ echo '{"debug": true}'; echo "{$SETTINGS}"; } > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$SANDBOX/two-values"
assert_exit 1 daemon_configured
: > "$STUB_LOG"
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "isn't one valid JSON object"
assert_exit 0 cmp -s "$DOCKER_DAEMON_CONFIG" "$SANDBOX/two-values"
assert_file_not_contains "$STUB_LOG" "dockerd"

# Several JSON values aren't configured, even when the last one is
{ cat "$SANDBOX/before-restart"; sorted /dev/stdin <<< "{$SETTINGS}"; } > "$DOCKER_DAEMON_CONFIG"
assert_exit 1 daemon_configured

# A running daemon: the pending item says the restart stops containers
stub systemctl '[ "$*" == "is-active --quiet docker.service" ]'
assert_contains "$(daemon_restart_note)" "stops running containers unless live-restore was already on"
stub systemctl 'exit 1'
assert_eq "" "$(daemon_restart_note)" "the note with no daemon running"
test_done
