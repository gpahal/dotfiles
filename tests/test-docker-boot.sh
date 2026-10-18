#!/bin/bash
set -euo pipefail
# os: ubuntu

# Docker starts at boot, so containers with a restart policy come back after a reboot:
# docker.service is enabled, and docker.socket is enabled and listening. The docker step enables
# either one that's off, and status reports each. It asks about the docker group on its own.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script docker/install.sh
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

# --- the docker group, asked on its own, since it's root-equivalent ---
# You're in the group once $SANDBOX/in-group exists, which usermod makes. confirm answers yes to
# every question but the group's while $SANDBOX/no-group exists.
stub id 'case "$1" in -un) echo me ;; -nG) [ -e "'"$SANDBOX"'/in-group" ] && echo "me docker" || echo me ;; esac'
stub usermod 'touch "'"$SANDBOX"'/in-group"'
eval "real_$(declare -f confirm)"
confirm() {
    if [[ "$1" == *"docker group"* ]] && [ -e "$SANDBOX/no-group" ]; then
        echo "$1 n"
        return 1
    fi
    real_confirm "$@"
}
unset DOTFILES_ASSUME_YES
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "info       me not in the docker group, which is optional: sudo docker works without it"
# Only the group is missing: no list of sudo changes, just its own question, declined without a
# terminal
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_not_contains "$RUN_OUTPUT" "already installed and set up"
assert_contains "$RUN_OUTPUT" "It's"
assert_contains "$RUN_OUTPUT" "root-equivalent"
assert_contains "$RUN_OUTPUT" "Left me out of the docker group."
assert_file_not_contains "$STUB_LOG" "usermod"
# The rest approved and the group declined: the rest is applied, and you stay out
unit service off
touch "$SANDBOX/no-group"
export DOTFILES_ASSUME_YES=1
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Applied."
assert_not_contains "$RUN_OUTPUT" "Add me to the docker group, so"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now docker.service"
assert_contains "$RUN_OUTPUT" "Left me out of the docker group."
assert_file_not_contains "$STUB_LOG" "usermod"
# The group approved: you're added, and told when it applies
rm "$SANDBOX/no-group"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo usermod -aG docker me"
assert_contains "$RUN_OUTPUT" "Added you to the docker group."
assert_exit 0 status
unset DOTFILES_ASSUME_YES
test_done
