#!/bin/bash
set -euo pipefail

# Install Docker Engine on Ubuntu from Docker's apt repo, the Linux counterpart of OrbStack on the
# Mac. The daemon starts at boot, so containers with a restart policy come back, `docker` works
# without sudo, and container logs rotate. These need sudo, so the step lists what's missing and
# asks once. On macOS, OrbStack (from the homebrew step) provides Docker.
#
# A temp HOME doesn't isolate this step, which changes the system with sudo and systemctl. Test it
# in an Ubuntu VM that runs systemd, such as an OrbStack machine.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
DOCKER_KEY_URL=https://download.docker.com/linux/ubuntu/gpg
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
# unattended-upgrades only installs from Ubuntu's own repos unless told otherwise. The origin and
# label come from Docker's Release file, e.g.
# https://download.docker.com/linux/ubuntu/dists/resolute/Release
DOCKER_UNATTENDED_CONF=/etc/apt/apt.conf.d/52dotfiles-docker
DOCKER_UNATTENDED_CONTENT='// From the dotfiles docker step: install Docker updates with the daily security updates
Unattended-Upgrade::Origins-Pattern { "origin=Docker,label=Docker CE"; };'
DOCKER_DAEMON_CONFIG=/etc/docker/daemon.json
DOCKER_DAEMON_KEYS="log-driver, live-restore, and localhost-only published ports"
OS_RELEASE=/etc/os-release
# The local log driver rotates each container's logs (5 files of 20 MB); json-file, the default,
# grows without limit. It applies to containers created after the change. live-restore keeps
# containers running while the daemon restarts, e.g. for an upgrade. Published ports listen on
# 127.0.0.1 unless given an address, since they bypass ufw: ip covers the default bridge, and
# default-network-opts the user-defined networks, such as Compose's, created after the change.
# ufw also blocks containers from reaching ports on the host. `sudo ufw allow in on docker0` lets in
# the default bridge, and each user-defined network's bridge, br-<first 12 characters of the
# network ID>, needs its own rule. The step adds neither.
DOCKER_DAEMON_SETTINGS='
    .["log-driver"] = "local" | .["live-restore"] = true | .ip = "127.0.0.1"
    | .["default-network-opts"].bridge["com.docker.network.bridge.host_binding_ipv4"] = "127.0.0.1"
    | if has("log-opts") then .["log-opts"] |= with_entries(select(
        .key | IN("max-size", "max-file", "compress", "labels", "labels-regex",
                  "env", "env-regex", "tag", "mode", "max-buffer-size")
      )) else . end'

docker_installed() {
    local package
    for package in "${DOCKER_PACKAGES[@]}"; do
        apt_installed "$package" || return 1
    done
}

docker_auto_updates_configured() {
    file_is "$DOCKER_UNATTENDED_CONF" "$DOCKER_UNATTENDED_CONTENT"
}

docker_sources() {
    cat <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(ubuntu_codename)
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $DOCKER_KEYRING
EOF
}

# Docker's Release file for this release, which is a 404 until Docker publishes packages for it
docker_release_url() {
    echo "https://download.docker.com/linux/ubuntu/dists/$(ubuntu_codename)/Release"
}

docker_source_ok() {
    file_is "$DOCKER_SOURCES" "$(docker_sources)"
}

# See add_apt_repo, whose return status this passes on
add_docker_repo() {
    add_apt_repo Docker "$DOCKER_SOURCES" "$(docker_sources)" "$DOCKER_KEY_URL" "$DOCKER_KEYRING" \
        "$(docker_release_url)"
}

# main runs it as `install_docker || ...`, where set -e is off, so each command checks its own failure
install_docker() {
    add_docker_repo || return $?
    # The packages' dependencies come from Ubuntu's sources
    if ! apt_get_update; then
        echo "  apt-get update failed; it may not be Docker's source. Fix the error above and re-run." >&2
        return 1
    fi
    apt_get install -y "${DOCKER_PACKAGES[@]}"
}

in_docker_group() {
    id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker
}

# docker.service wants containerd.service, so it starts containerd too
starts_at_boot() {
    systemctl is-enabled --quiet docker.service 2>/dev/null
}

# docker.service requires docker.socket, which also restarts a stopped daemon on the next docker
# command. The socket is enabled separately from the service.
socket_ready() {
    systemctl is-enabled --quiet docker.socket 2>/dev/null &&
        systemctl is-active --quiet docker.socket 2>/dev/null
}

# Succeeds when the daemon config on stdin already has the settings
daemon_settings_applied() {
    local current
    current="$(cat)"
    [ -n "$current" ] && jq -e "($DOCKER_DAEMON_SETTINGS) == ." <<< "$current" &> /dev/null
}

daemon_config_unreadable() {
    [ -e "$DOCKER_DAEMON_CONFIG" ] && [ ! -r "$DOCKER_DAEMON_CONFIG" ]
}

# Reads without sudo, or with sudo only when it doesn't ask for a password. A file only root can
# read is otherwise unverified, so main lists it to check after approval.
daemon_configured() {
    if [ -r "$DOCKER_DAEMON_CONFIG" ]; then
        daemon_settings_applied < "$DOCKER_DAEMON_CONFIG"
    else
        sudo -n cat "$DOCKER_DAEMON_CONFIG" 2> /dev/null | daemon_settings_applied
    fi
}

# What applying the daemon settings does to a running daemon, for the pending list
daemon_restart_note() {
    systemctl is-active --quiet docker.service 2>/dev/null || return 0
    printf '%s' ". This restarts the running daemon, which stops running containers unless"
    printf '%s' " live-restore was already on; only those with a restart policy come back. The port"
    printf '%s' " binding applies to the default bridge, and to networks created from now on"
}

# Information, not something the step sets up: what images, containers, volumes, and the build
# cache take on disk, so you can prune before the disk fills. docker.socket would start a stopped
# daemon on the first docker command, so it's only asked when docker.service is already running.
# It prunes nothing.
status_docker_usage() {
    local label="Docker disk usage" out status=0 type count size reclaimable summary=""
    if [ -n "${DOTFILES_STATUS_QUICK:-}" ]; then
        status_item unverified "$label: skipped by --quick"
        return 0
    fi
    if ! systemctl is-active --quiet docker.service 2>/dev/null; then
        status_item info "$label: the daemon isn't running, and status doesn't start it"
        return 0
    fi
    # One line per type: Images, Containers, Local Volumes, and Build Cache. Docker's output has
    # had these fields since 17.06; the reclaimable space may end in a percentage.
    out="$(run_bounded 30 docker system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}' 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
        case "$out" in
            *"permission denied"*)
                status_item unverified "$label: $(id -un) can't reach the daemon's socket yet; log out and back in, so the docker group applies, then check it"
                ;;
            *"Cannot connect to the Docker daemon"* | *"Is the docker daemon running"*)
                status_item info "$label: the daemon isn't running"
                ;;
            *)
                [ "$status" -ne 124 ] || out="docker system df didn't answer within 30 s"
                status_item info "$label: couldn't check ($(grep -v '^ *$' <<< "$out" | head -n 1))"
                ;;
        esac
        return 0
    fi
    while IFS=$'\t' read -r type count size reclaimable; do
        [ -n "$type" ] && [ -n "$size" ] && [[ "$count" =~ ^[0-9]+$ ]] || continue
        reclaimable="${reclaimable%% (*}"
        summary="${summary:+$summary; }$(tr '[:upper:]' '[:lower:]' <<< "$type") $count, $size"
        case "$reclaimable" in
            "" | 0B) ;;
            *) summary="$summary ($reclaimable reclaimable)" ;;
        esac
    done <<< "$out"
    if [ -n "$summary" ]; then
        status_item info "$label: $summary"
    else
        status_item info "$label: couldn't read docker system df's output"
    fi
}

# Never asks for sudo. A config only root can read is checked with sudo -n when sudo credentials
# are cached, and is otherwise unverified.
status() {
    if is_macos; then
        status_item skipped "Docker: OrbStack, from the homebrew step, provides it on macOS"
        return 0
    fi
    local installed=false
    docker_installed && installed=true
    status_check "Docker Engine from Docker's apt repo" "$installed"
    ! "$installed" || status_apt_source Docker "$DOCKER_SOURCES" "$(docker_sources)" docker "$(docker_release_url)"
    status_check "$(id -un) in the docker group" in_docker_group
    if "$installed"; then
        status_check "Docker starts at boot (docker.service enabled)" starts_at_boot
        status_check "docker.socket enabled and listening" socket_ready
    else
        status_item missing "Docker starts at boot (docker.service enabled)"
        status_item missing "docker.socket enabled and listening"
    fi
    if ! "$installed" || [ ! -e "$DOCKER_DAEMON_CONFIG" ]; then
        status_item missing "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"
    elif daemon_config_unreadable && ! sudo_cached; then
        status_item unverified "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG (only root can read it; run sudo -v, then status, to check it)"
    elif status_require_cmd jq "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"; then
        status_check "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG" daemon_configured
    fi
    status_check "Docker origins allowed in unattended-upgrades ($DOCKER_UNATTENDED_CONF)" docker_auto_updates_configured
    ! "$installed" || status_docker_usage
    status_result
}

# Merge the settings into the file, keeping its other keys. Nothing is written until jq succeeds.
configure_daemon() {
    local current='{}' exists=false tmp backup="$DOCKER_DAEMON_CONFIG.dotfiles-bak" running=false
    if sudo test -e "$DOCKER_DAEMON_CONFIG"; then
        exists=true
        if ! current="$(sudo cat "$DOCKER_DAEMON_CONFIG")"; then
            echo "  Couldn't read $DOCKER_DAEMON_CONFIG." >&2
            return 1
        fi
        # jq reads an empty file as no input and prints nothing
        [ -n "${current//[[:space:]]/}" ] || current='{}'
    fi
    tmp="$(mktemp)" || return 1
    if ! printf '%s\n' "$current" | jq "$DOCKER_DAEMON_SETTINGS" > "$tmp"; then
        rm -f "$tmp"
        echo "  $DOCKER_DAEMON_CONFIG isn't valid JSON; fix it and re-run." >&2
        return 1
    fi
    if daemon_settings_applied <<< "$current"; then
        rm -f "$tmp"
        echo "  $DOCKER_DAEMON_CONFIG already sets $DOCKER_DAEMON_KEYS."
        return 0
    fi
    if ! sudo dockerd --validate --config-file "$tmp"; then
        rm -f "$tmp"
        echo "  Docker rejected the proposed configuration; $DOCKER_DAEMON_CONFIG is unchanged." >&2
        return 1
    fi
    # A backup to put back if Docker won't restart with the new file. It goes once Docker does.
    if "$exists" && ! sudo cp -p "$DOCKER_DAEMON_CONFIG" "$backup"; then
        rm -f "$tmp"
        return 1
    fi
    # A failed write leaves the old file whole. main runs this as `configure_daemon || ...`, where
    # set -e is off, so each command checks its own failure.
    if ! install_root_file "$tmp" "$DOCKER_DAEMON_CONFIG"; then
        rm -f "$tmp"
        "$exists" && sudo rm -f "$backup"
        return 1
    fi
    rm -f "$tmp"
    # Only a running daemon needs the restart; a stopped one reads the file when it starts
    systemctl is-active --quiet docker.service && running=true
    if ! sudo systemctl try-restart docker.service; then
        if "$exists"; then
            if ! install_root_file "$backup" "$DOCKER_DAEMON_CONFIG"; then
                echo "  Docker activation failed, and putting the previous configuration back failed too. Copy $backup to $DOCKER_DAEMON_CONFIG by hand." >&2
                return 1
            fi
            echo "  Docker activation failed; restored the previous configuration, which is also in $backup. Fix the error and re-run." >&2
        else
            sudo rm -f "$DOCKER_DAEMON_CONFIG" || return 1
            echo "  Docker activation failed; removed the new configuration. Fix the error and re-run." >&2
        fi
        if "$running"; then
            sudo systemctl start docker.service ||
                echo "  Docker couldn't recover with its previous configuration. Check: journalctl -u docker" >&2
        fi
        return 1
    fi
    # Docker took the new file
    if "$exists"; then
        sudo rm -f "$backup"
    fi
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Setting up Docker..."
    if is_macos; then
        echo "  OrbStack, from the homebrew step, provides Docker; skipping."
        return 0
    fi
    require_supported_os || return 1
    require_cmd jq || return 1
    require_cmd curl || return 1

    # Installed Docker updates only while its source is the one this step writes. A release upgrade
    # turns third-party sources off, and a re-run rewrites this one for the new release once Docker
    # publishes packages for it. A fresh install needs those packages for everything else here.
    local repair_source=false
    if ! docker_installed && ! apt_repo_published Docker "$(docker_release_url)"; then
        return 0
    fi
    if docker_installed && ! docker_source_ok && apt_repo_published Docker "$(docker_release_url)"; then
        repair_source=true
    fi
    local pending=()
    docker_installed || pending+=("Install ${DOCKER_PACKAGES[*]} from Docker's apt repo")
    ! "$repair_source" ||
        pending+=("Rewrite Docker's apt source for $(ubuntu_codename) ($(apt_source_state "$DOCKER_SOURCES" "$(docker_sources)")): write $DOCKER_SOURCES")
    in_docker_group || pending+=("Add $(id -un) to the docker group, so docker runs without sudo. The group is root-equivalent: anything running as you, agents included, can get root with docker run -v /:/host")
    # Freshly installed packages enable and start both units
    if docker_installed && ! starts_at_boot; then
        pending+=("Start Docker at boot, so containers with a restart policy come back: enable docker.service")
    fi
    if docker_installed && ! socket_ready; then
        pending+=("Enable docker.socket")
    fi
    if ! docker_installed || ! daemon_configured; then
        if daemon_config_unreadable; then
            pending+=("Check $DOCKER_DAEMON_CONFIG and set $DOCKER_DAEMON_KEYS in it$(daemon_restart_note)")
        else
            pending+=("Rotate container logs, keep containers up across daemon restarts, and publish ports on 127.0.0.1 unless given an address: set $DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG$(daemon_restart_note)")
        fi
    fi
    docker_auto_updates_configured || pending+=("Let unattended-upgrades install Docker updates: write $DOCKER_UNATTENDED_CONF")

    local result=0 repo_status=0
    if [ ${#pending[@]} -eq 0 ]; then
        echo "  Docker is already installed and set up."
        return 0
    fi
    confirm_sudo_changes "${pending[@]}" || return 0
    if ! docker_installed; then
        install_docker || repo_status=$?
        # The rest needs Docker's packages, and the docker group they add
        [ "$repo_status" -ne "$APT_REPO_UNPUBLISHED" ] || return 0
        [ "$repo_status" -eq 0 ] || return 1
    elif "$repair_source"; then
        add_docker_repo || repo_status=$?
        [ "$repo_status" -eq 0 ] || [ "$repo_status" -eq "$APT_REPO_UNPUBLISHED" ] || result=1
    fi
    # Each part from here on runs whether or not the one before it failed
    if ! in_docker_group; then
        sudo usermod -aG docker "$(id -un)" || result=1
        echo "  Added you to the docker group. New logins get it, but your user services (the T3 Code"
        echo "  service and its agents) and a running tmux server keep their old groups until you"
        echo "  reboot, or run sudo systemctl restart user@\$(id -u), which stops them."
    fi
    socket_ready || sudo systemctl enable --now docker.socket || result=1
    # After the config, so a daemon this starts reads it rather than restarting for it
    daemon_configured || configure_daemon || result=1
    starts_at_boot || sudo systemctl enable --now docker.service || result=1
    docker_auto_updates_configured ||
        write_root_file "$DOCKER_UNATTENDED_CONF" "$DOCKER_UNATTENDED_CONTENT" || result=1
    if [ "$result" -ne 0 ]; then
        echo "  Applied the rest. Some changes failed; see the errors above." >&2
        return 1
    fi
    echo "  Applied."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
