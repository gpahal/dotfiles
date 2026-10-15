#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The docker step merges log-driver, live-restore, and 127.0.0.1 as the address published ports
# bind to into /etc/docker/daemon.json, keeping the file's other keys and mode, restarts a running
# daemon only when the file changed, and leaves invalid JSON alone. A failed write leaves the old
# file whole, and a failed restart puts it back and keeps a backup, which goes once Docker takes
# the new file. test-docker-sources.sh covers the conflicting-package skip.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script docker/install.sh
is_macos() { false; }
is_ubuntu() { true; }
stub sudo 'exec env "$@"'
stub systemctl
stub dockerd
DOCKER_DAEMON_CONFIG="$SANDBOX/etc/docker/daemon.json"
SETTINGS='"log-driver": "local", "live-restore": true, "ip": "127.0.0.1",
    "default-network-opts": {"bridge": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}}'
# Compact, with sorted keys, to compare with the expected JSON
sorted() {
    jq -S -c . "${1:-$DOCKER_DAEMON_CONFIG}"
}

# No file: it's created, world-readable, and the daemon restarted if it runs
assert_exit 0 configure_daemon
assert_eq "$(sorted <<< "{$SETTINGS}")" "$(sorted)" "a new daemon.json"
assert_eq "-rw-r--r--" "$(/bin/ls -l "$DOCKER_DAEMON_CONFIG" | cut -c1-10)" "mode of a new daemon.json"
assert_file_contains "$STUB_LOG" "systemctl try-restart docker.service"
assert_exit 0 daemon_configured

# Already set: nothing written or restarted
: > "$STUB_LOG"
before="$(/bin/ls -li "$DOCKER_DAEMON_CONFIG")"
assert_exit 0 configure_daemon
assert_contains "$RUN_OUTPUT" "already sets log-driver, live-restore, and localhost-only published ports"
assert_eq "$before" "$(/bin/ls -li "$DOCKER_DAEMON_CONFIG")" "daemon.json after a re-run"
assert_file_not_contains "$STUB_LOG" "systemctl"

# Driver-specific options don't survive the switch to local; compatible limits and other
# daemon settings do. Once Docker restarts with the new file, no backup or temp file is left.
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

# Failed activation restores the original and keeps the backup, so the next run retries rather
# than claiming done.
printf '{"log-driver":"json-file"}\n' > "$DOCKER_DAEMON_CONFIG"
cp "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-restart"
stub systemctl '[ "$1" != try-restart ] || exit 1'
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "$DOCKER_DAEMON_CONFIG.dotfiles-bak"
assert_exit 0 cmp -s "$DOCKER_DAEMON_CONFIG" "$SANDBOX/before-restart"
assert_exit 0 cmp -s "$DOCKER_DAEMON_CONFIG.dotfiles-bak" "$SANDBOX/before-restart"
stub systemctl
: > "$STUB_LOG"
assert_exit 0 configure_daemon
assert_file_contains "$STUB_LOG" 'systemctl try-restart docker.service'
# The retry's restart worked, so the backup is gone
assert_eq daemon.json "$(/bin/ls -A "$(dirname "$DOCKER_DAEMON_CONFIG")")" "files beside daemon.json after a retry"

# Other keys are kept, a setting with another value is replaced, and the file keeps its mode
echo '{"dns": ["1.1.1.1"], "log-driver": "json-file", "ip": "0.0.0.0"}' > "$DOCKER_DAEMON_CONFIG"
chmod 640 "$DOCKER_DAEMON_CONFIG"
assert_exit 1 daemon_configured
assert_exit 0 configure_daemon
assert_eq "$(sorted <<< "{\"dns\": [\"1.1.1.1\"], $SETTINGS}")" "$(sorted)" "a merged daemon.json"
assert_eq "-rw-r-----" "$(/bin/ls -l "$DOCKER_DAEMON_CONFIG" | cut -c1-10)" "mode of a merged daemon.json"

# An empty file counts as {}
: > "$DOCKER_DAEMON_CONFIG"
assert_exit 0 configure_daemon
assert_eq "$(sorted <<< "{$SETTINGS}")" "$(sorted)" "daemon.json from an empty file"

# Invalid JSON: left as it is, and the step fails
echo '{"dns": [' > "$DOCKER_DAEMON_CONFIG"
: > "$STUB_LOG"
assert_exit 1 configure_daemon
assert_contains "$RUN_OUTPUT" "isn't valid JSON"
assert_eq '{"dns": [' "$(cat "$DOCKER_DAEMON_CONFIG")" "invalid daemon.json"
assert_file_not_contains "$STUB_LOG" "systemctl"

# A running daemon: the pending item says the restart stops containers
stub systemctl '[ "$*" == "is-active --quiet docker.service" ]'
assert_contains "$(daemon_restart_note)" "stops running containers unless live-restore was already on"
stub systemctl 'exit 1'
assert_eq "" "$(daemon_restart_note)" "the note with no daemon running"
test_done
