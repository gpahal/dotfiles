#!/bin/bash
set -euo pipefail

# Docker starts at boot, so containers with a restart policy come back after a reboot:
# docker.service is enabled, and docker.socket is enabled and listening. The docker step enables
# either one that's off, and status reports each. Only the run that installs Docker asks about the
# docker group (test-docker-sources.sh), and status says how to join it.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script docker/install.sh
# No containerd shim runs, so a stopped daemon runs no containers
stub pgrep 'exit 1'
is_macos() { false; }
is_ubuntu() { true; }

# Docker's packages are installed, you're in the docker group, and the daemon config is set.
# docker.service is enabled when $SANDBOX/service says "on", and docker.socket is enabled and
# active when $SANDBOX/socket does; enabling either turns it on. The daemon isn't running, so
# status doesn't run docker.
stub dpkg-query 'case "${!#}" in docker-ce | docker-ce-cli | containerd.io | docker-*-plugin) echo "install ok installed" ;; esac'
stub id 'case "$1" in -un) echo me ;; -nG) echo "me docker" ;; esac'
stub systemctl 'case "$*" in
    "enable --now docker.service") echo on > "'"$SANDBOX"'/service" ;;
    "is-enabled --quiet docker.service") [ "$(cat "'"$SANDBOX"'/service")" == on ] ;;
    "enable --now docker.socket") echo on > "'"$SANDBOX"'/socket" ;;
    *docker.socket*) [ "$(cat "'"$SANDBOX"'/socket")" == on ] ;;
    *) exit 1 ;;
esac'
stub_sudo_exec
# The step requires gpg, which a bare ubuntu:26.04 lacks; its key has the pinned fingerprint
stub gpg "printf 'pub:-\\nfpr:::::::::%s:\\n' $DOCKER_KEY_FPR"
# Docker's apt source lists this release
OS_RELEASE="$SANDBOX/os-release"
printf '%s\n' ID=ubuntu VERSION_CODENAME=resolute > "$OS_RELEASE"
APT_SOURCES_DIR="$SANDBOX/apt/sources.list.d"
DOCKER_SOURCES="$APT_SOURCES_DIR/docker.sources"
mkdir -p "$APT_SOURCES_DIR"
stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
docker_sources > "$DOCKER_SOURCES"
DOCKER_DAEMON_CONFIG="$SANDBOX/daemon.json"
jq "$DOCKER_DAEMON_SETTINGS" <<< '{}' > "$DOCKER_DAEMON_CONFIG"
DOCKER_UNATTENDED_CONF="$SANDBOX/52dotfiles-docker"
printf '%s\n' "$DOCKER_UNATTENDED_CONTENT" > "$DOCKER_UNATTENDED_CONF"
unit() {
    echo "$2" > "$SANDBOX/$1"
}

# Both are on: nothing to do
unit service on
unit socket on
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Docker is already installed and set up."
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Docker starts at boot"
assert_contains "$RUN_OUTPUT" "ok         docker.socket enabled and listening"

# The service is disabled: status says so, and the step lists enabling it
unit service off
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Docker starts at boot"
assert_contains "$RUN_OUTPUT" "ok         docker.socket enabled and listening"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Start Docker at boot, so containers with a restart policy come back: enable docker.service"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$STUB_LOG" "sudo"

# The socket is disabled: status says so, and the step lists enabling it
unit service on
unit socket off
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "ok         Docker starts at boot"
assert_contains "$RUN_OUTPUT" "missing    docker.socket enabled and listening"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Enable docker.socket"
assert_file_not_contains "$STUB_LOG" "sudo"

# Approved, each is enabled and started, and nothing is disabled
unit service off
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now docker.service"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now docker.socket"
assert_file_not_contains "$STUB_LOG" "systemctl disable"
assert_exit 0 status

# --- the docker group, which only the run that installs Docker asks about ---
stub id 'case "$1" in -un) echo me ;; -nG) echo me ;; esac'
unset DOTFILES_ASSUME_YES
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "info       me not in the docker group, which is optional: sudo docker works without it; sudo usermod -aG docker me adds you, and is root-equivalent"
# Docker already installed and only the group missing: set up, with no question
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_contains "$RUN_OUTPUT" "Docker is already installed and set up."
assert_not_contains "$RUN_OUTPUT" "docker group"
# Other changes approved: still no question about the group
unit service off
export DOTFILES_ASSUME_YES=1
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Applied."
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now docker.service"
assert_not_contains "$RUN_OUTPUT" "docker group"
assert_file_not_contains "$STUB_LOG" "usermod"
unset DOTFILES_ASSUME_YES
test_done
