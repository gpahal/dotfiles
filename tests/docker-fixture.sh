# Helpers for tests of the docker step. Source after tests/lib.sh; call docker_sandbox_paths after
# each load_script docker/install.sh, which resets the paths. It fails the test when a step
# constant still names a system path.
# shellcheck shell=bash
# shellcheck disable=SC2034 # the step reads them

docker_sandbox_paths() {
    DOCKER_KEYRING="$SANDBOX/keyrings/docker.asc"
    DOCKER_SOURCES="$APT_SOURCES_DIR/docker.sources"
    DOCKER_UNATTENDED_CONF="$SANDBOX/apt/apt.conf.d/52dotfiles-docker"
    DOCKER_DAEMON_CONFIG="$SANDBOX/docker/daemon.json"
    _docker_system_paths_left
}

_docker_system_paths_left() {
    local name left=""
    while IFS= read -r name; do
        case "${!name}" in
            /etc* | /var* | /usr* | /run* | /dev*) left="$left $name=${!name}" ;;
        esac
    done < <(sed -nE 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "$REPO_DIR/docker/install.sh" | sort -u)
    [ -z "$left" ] || fail "docker_sandbox_paths left these on the real machine:$left"
}

# id says you're me, in the docker group while $SANDBOX/in-group exists
stub_docker_group() {
    stub id 'case "$1" in -un) echo me ;; -nG) [ -e "'"$SANDBOX"'/in-group" ] && echo "me docker" || echo me ;; esac'
}

# dpkg-query reports the packages listed in $SANDBOX/installed
stub_docker_packages() {
    : > "$SANDBOX/installed"
    stub dpkg-query 'for p in "$@"; do
    case "$p" in -*) continue ;; esac
    grep -qxF "$p" "'"$SANDBOX"'/installed" && echo "install ok installed" || echo "unknown ok not-installed"
done'
}

# Docker installed and set up as the step leaves it, with you in the docker group. Needs
# stub_docker_packages, stub_docker_group, and stub_dpkg_arch.
docker_set_up() {
    printf '%s\n' "${DOCKER_PACKAGES[@]}" > "$SANDBOX/installed"
    mkdir -p "$(dirname "$DOCKER_DAEMON_CONFIG")" "$(dirname "$DOCKER_UNATTENDED_CONF")" "$(dirname "$DOCKER_SOURCES")"
    jq "$DOCKER_DAEMON_SETTINGS" <<< '{}' > "$DOCKER_DAEMON_CONFIG"
    printf '%s\n' "$DOCKER_UNATTENDED_CONTENT" > "$DOCKER_UNATTENDED_CONF"
    docker_sources > "$DOCKER_SOURCES"
    touch "$SANDBOX/in-group"
}
