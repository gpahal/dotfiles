# Helpers for tests of the docker step. Source after tests/lib.sh, and call sandbox_paths
# docker/install.sh after each load_script docker/install.sh.
# shellcheck shell=bash

# id says you're me, in the docker group while $SANDBOX/in-group exists
stub_docker_group() {
    stub id 'case "$1" in -un) echo me ;; -nG) [ -e "$SANDBOX/in-group" ] && echo "me docker" || echo me ;; esac'
    # shellcheck disable=SC2034 # the docker step reads it
    CURRENT_USER=me
}

# Docker installed and set up as the step leaves it, with you in the docker group. Needs
# stub_apt_packages, stub_docker_group, and stub_dpkg_arch.
docker_set_up() {
    printf '%s\n' "${DOCKER_PACKAGES[@]}" > "$SANDBOX/installed"
    mkdir -p "$(dirname "$DOCKER_DAEMON_CONFIG")" "$(dirname "$DOCKER_UNATTENDED_CONF")" "$(dirname "$DOCKER_SOURCES")"
    jq "$DOCKER_DAEMON_SETTINGS" <<< '{}' > "$DOCKER_DAEMON_CONFIG"
    printf '%s\n' "$DOCKER_UNATTENDED_CONTENT" > "$DOCKER_UNATTENDED_CONF"
    docker_sources > "$DOCKER_SOURCES"
    touch "$SANDBOX/in-group"
}
