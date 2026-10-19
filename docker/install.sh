#!/bin/bash
set -euo pipefail

# Install Docker Engine from Docker's apt repo, started at boot.
#
# Install Docker Engine on Ubuntu from Docker's apt repo, the Linux counterpart of OrbStack on the
# Mac. The daemon starts at boot, so containers with a restart policy come back, container logs
# rotate, containers keep running across daemon restarts, published ports listen on 127.0.0.1,
# networks stay out of the SSH ranges, and Docker updates install with the daily security updates.
# These need sudo, so the step lists what's missing and asks once. The run that installs Docker then
# asks on its own whether to add you to the docker group, which lets `docker` run without sudo but
# is root-equivalent; without it, use sudo docker. Status says how to join it later. On macOS,
# OrbStack (from the homebrew step) provides Docker.
#
# A temp HOME doesn't isolate this step, which changes the system with sudo and systemctl. Test it
# in an Ubuntu VM that runs systemd, such as an OrbStack machine.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"

STEP_OS=ubuntu
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
DOCKER_KEY_URL=https://download.docker.com/linux/ubuntu/gpg
# The fingerprint of Docker's release key, "Docker Release (CE deb)"
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
# unattended-upgrades only installs from Ubuntu's own repos unless told otherwise. The origin and
# label come from Docker's Release file, e.g.
# https://download.docker.com/linux/ubuntu/dists/resolute/Release
DOCKER_UNATTENDED_CONF=/etc/apt/apt.conf.d/52dotfiles-docker
DOCKER_UNATTENDED_CONTENT='// From the dotfiles docker step: install Docker updates with the daily security updates
Unattended-Upgrade::Origins-Pattern { "origin=Docker,label=Docker CE"; };'
DOCKER_DAEMON_CONFIG=/etc/docker/daemon.json
DOCKER_DAEMON_KEYS="log-driver, live-restore, localhost-only published ports, and address pools"
# The local log driver rotates each container's logs (5 files of 20 MB); json-file, the default,
# grows without limit. It applies to containers created after the change. live-restore keeps
# containers running while the daemon restarts, e.g. for an upgrade. Published ports listen on
# 127.0.0.1 unless given an address, since they bypass ufw: ip covers the default bridge, and
# default-network-opts the user-defined networks, such as Compose's, created after the change.
# Docker's default address pools are 172.17.0.0/16 to 172.31.0.0/16, then 192.168.0.0/16 in /20s,
# and the ubuntu step's ufw lets SSH in from 192.168.0.0/16. default-address-pools keeps the same
# 172.17.0.0 to 172.31.255.255, split into /24s, so a network created after the change stays out
# of the SSH ranges, with room for thousands of networks, where 15 /16s would run out with a
# Compose project per worktree. docker0 keeps the subnet Docker's network store gave it when the
# daemon first started, through a reboot or a deleted docker0: 172.17.0.0/16, since the packages
# start Docker before the step writes this file.
# ufw blocks containers from reaching ports on the host. The ubuntu step's SSH ranges leave out
# 172.16.0.0/12, and it denies SSH on docker0 and br-+ ahead of them, for a network with IPv6 or
# a subnet in the SSH ranges. `sudo ufw allow in on docker0` lets the default bridge reach the
# other ports, and each user-defined network's bridge, br-<first 12 characters of the network ID>,
# needs its own rule. The step adds neither.
DOCKER_DAEMON_SETTINGS='
    .["log-driver"] = "local" | .["live-restore"] = true | .ip = "127.0.0.1"
    | .["default-network-opts"].bridge["com.docker.network.bridge.host_binding_ipv4"] = "127.0.0.1"
    | .["default-address-pools"] = [
        {base: "172.17.0.0/16", size: 24}, {base: "172.18.0.0/15", size: 24},
        {base: "172.20.0.0/14", size: 24}, {base: "172.24.0.0/13", size: 24}]
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

# Run it once apt_repo_published says Docker has packages for this release
add_docker_repo() {
    add_apt_repo Docker "$DOCKER_SOURCES" "$(docker_sources)" "$DOCKER_KEY_URL" "$DOCKER_KEYRING" "$DOCKER_KEY_FPR"
}

# apply runs it as `install_docker || ...`, where set -e is off, so each command checks its own
# failure
install_docker() {
    add_docker_repo || return 1
    # The packages' dependencies come from Ubuntu's sources
    if ! apt_get_update; then
        echo "  apt-get update failed; it may not be Docker's source. Fix the error above and re-run." >&2
        return 1
    fi
    apt_get install -y "${DOCKER_PACKAGES[@]}"
}

# From the group database, so it's true once you've joined, before a new login gives your
# processes the group
in_docker_group() {
    case " $(id -nG "$(id -un)") " in *" docker "*) ;; *) return 1 ;; esac
}

# sudo_cached, as status found it once, for its checks that run docker or read the config
sudo_ready() {
    if [ -n "${SUDO_CACHED_CACHE:-}" ]; then
        [ "$SUDO_CACHED_CACHE" == yes ]
        return
    fi
    sudo_cached
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

enable_docker_service() {
    sudo systemctl enable --now docker.service
}

enable_docker_socket() {
    sudo systemctl enable --now docker.socket
}

write_docker_auto_updates() {
    write_root_file "$DOCKER_UNATTENDED_CONF" "$DOCKER_UNATTENDED_CONTENT"
}

# The step's items, in the order apply fixes them: the packages first, since the rest needs them,
# then the socket, then the daemon config, so a daemon that starting at boot starts reads it
# rather than restarting for it. The daemon item's pending text says when it can't be read
# without sudo, and what a restart does to a running daemon.
docker_items() {
    local daemon_pending="Rotate container logs, keep containers up across daemon restarts, publish ports on 127.0.0.1 unless given an address, and give new networks /24s outside 192.168.0.0/16: set $DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"
    daemon_config_unreadable && daemon_pending="Check $DOCKER_DAEMON_CONFIG and set $DOCKER_DAEMON_KEYS in it"
    items_reset
    item --sudo "Docker Engine from Docker's apt repo" "Install ${DOCKER_PACKAGES[*]} from Docker's apt repo" \
        docker_installed install_docker
    item --sudo "docker.socket enabled and listening" "Enable docker.socket" socket_ready enable_docker_socket
    item --sudo "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG" "$daemon_pending$(daemon_restart_note)" \
        daemon_configured configure_daemon
    item --sudo "Docker starts at boot (docker.service enabled)" \
        "Start Docker at boot, so containers with a restart policy come back: enable docker.service" \
        starts_at_boot enable_docker_service
    item --sudo "Docker origins allowed in unattended-upgrades ($DOCKER_UNATTENDED_CONF)" \
        "Let unattended-upgrades install Docker updates: write $DOCKER_UNATTENDED_CONF" \
        docker_auto_updates_configured write_docker_auto_updates
}

# Succeeds when the daemon config on stdin already has the settings
daemon_settings_applied() {
    local current
    current="$(cat)"
    [ -n "$current" ] && jq -s -e "length == 1 and (.[0] | ($DOCKER_DAEMON_SETTINGS) == .)" <<< "$current" &> /dev/null
}

daemon_config_unreadable() {
    [ -e "$DOCKER_DAEMON_CONFIG" ] && [ ! -r "$DOCKER_DAEMON_CONFIG" ]
}

# Reads without sudo, or with sudo only when it doesn't ask for a password. A file only root can
# read is otherwise unverified, so apply lists it to check after approval.
daemon_configured() {
    read_root_file "$DOCKER_DAEMON_CONFIG" -n | daemon_settings_applied
}

# What applying the daemon settings does to a running daemon, for the pending list
daemon_restart_note() {
    systemctl is-active --quiet docker.service 2>/dev/null || return 0
    printf '%s' ". This restarts the running daemon, which stops running containers unless"
    printf '%s' " live-restore was already on; only those with a restart policy come back. The port"
    printf '%s' " binding applies to the default bridge, and to networks created from now on"
}

# docker_status_run <label> <docker args>...: run docker for a status check, stopped after 30 s,
# leaving its output in DOCKER_OUT and its exit status in DOCKER_STATUS, which the caller declares
# local. Outside the docker group it goes through sudo -n, which runs only while sudo credentials
# are cached, since logging in again can't help. Returns 0 when docker succeeded; 1 when it
# reported, under the label, why docker couldn't be asked; and 2 when docker failed otherwise,
# which the caller reports.
docker_status_run() {
    local label="$1" docker=(docker)
    shift
    DOCKER_OUT=""
    DOCKER_STATUS=0
    if ! in_docker_group; then
        if ! sudo_ready; then
            status_item unverified "$label: $(id -un) isn't in the docker group; run sudo -v, then status, to check it"
            return 1
        fi
        docker=(sudo -n docker)
    fi
    DOCKER_OUT="$(run_bounded 30 "${docker[@]}" "$@" 2>&1)" || DOCKER_STATUS=$?
    [ "$DOCKER_STATUS" -ne 0 ] || return 0
    case "$DOCKER_OUT" in
        # In the group, but this session started before joining it
        *"permission denied"*)
            status_item unverified "$label: $(id -un) can't reach the daemon's socket yet; log out and back in, so the docker group applies, then check it"
            ;;
        # Stopped since the caller saw it running, as a restart does
        *"Cannot connect to the Docker daemon"* | *"Is the docker daemon running"*)
            status_item info "$label: the daemon isn't running"
            ;;
        *) return 2 ;;
    esac
    return 1
}

# Information, not something the step sets up: what images, containers, volumes, and the build
# cache take on disk, so you can prune before the disk fills. docker.socket would start a stopped
# daemon on the first docker command, so it's only asked when docker.service is already running.
# It prunes nothing.
status_docker_usage() {
    local label="Docker disk usage" out status=0 type count size reclaimable summary="" DOCKER_OUT DOCKER_STATUS
    if status_quick; then
        status_item unverified "$label: skipped by --quick"
        return 0
    fi
    if ! systemctl is-active --quiet docker.service 2>/dev/null; then
        status_item info "$label: the daemon isn't running, and status doesn't start it"
        return 0
    fi
    # One line per type: Images, Containers, Local Volumes, and Build Cache. Docker's output has
    # had these fields since 17.06; the reclaimable space may end in a percentage.
    docker_status_run "$label" system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}' || status=$?
    [ "$status" -ne 1 ] || return 0
    out="$DOCKER_OUT"
    if [ "$status" -ne 0 ]; then
        [ "$DOCKER_STATUS" -ne 124 ] || out="docker system df didn't answer within 30 s"
        status_item info "$label: couldn't check ($(grep -v '^ *$' <<< "$out" | head -n 1))"
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

# Print each port a published port list from docker ps binds on every address, one per line, such
# as 0.0.0.0:8080->80/tcp. Docker lists IPv6 ones as [::]:<port>, or :::<port> before 26.
ports_on_every_address() {
    local nl=$'\n'
    printf '%s\n' "${1//, /$nl}" | grep -E '^(0\.0\.0\.0|\[::\]|::):[^ ]*->' || true
}

# Published ports skip ufw, since Docker's iptables rules come first. The daemon settings bind them
# to 127.0.0.1, but not on a network created before them, or for a port published on 0.0.0.0, so
# status lists the running containers' ports that every address reaches. docker.socket would start
# a stopped daemon, so a stopped one isn't asked. live-restore keeps containers running while it's
# stopped, each under a containerd-shim-runc-v2 process in containerd's moby namespace, which
# Docker's are; other containerd clients, such as k3s, use their own. The [m] keeps the pattern
# from matching a shell whose command line holds it.
status_docker_ports() {
    local label="Container ports published on every address, which ufw doesn't filter"
    local none="No container ports published on every address, which ufw doesn't filter"
    local out status=0 name ports open="" port DOCKER_OUT DOCKER_STATUS
    if ! systemctl is-active --quiet docker.service 2>/dev/null; then
        if pgrep -f 'containerd-shi[m].* -namespace moby( |$)' > /dev/null 2>&1; then
            status_item unknown "$label: containers are running while the Docker daemon is down, so their published ports can't be checked; start it with sudo systemctl start docker"
        else
            status_item ok "$none: the daemon isn't running"
        fi
        return 0
    fi
    docker_status_run "$label" ps --format '{{.Names}}\t{{.Ports}}' || status=$?
    [ "$status" -ne 1 ] || return 0
    out="$DOCKER_OUT"
    if [ "$status" -ne 0 ]; then
        [ "$DOCKER_STATUS" -ne 124 ] || out="docker ps didn't answer within 30 s"
        status_item unknown "$label: couldn't list the containers ($(grep -v '^ *$' <<< "$out" | head -n 1))"
        return 0
    fi
    while IFS=$'\t' read -r name ports; do
        while IFS= read -r port; do
            [ -z "$port" ] || open="${open:+$open, }$name $port"
        done < <(ports_on_every_address "$ports")
    done <<< "$out"
    if [ -z "$open" ]; then
        status_item ok "$none"
    else
        status_item missing "$label: $open; recreate each with -p 127.0.0.1:<port>:<container port>, or on a network created since the docker step ran"
    fi
}

# Never asks for sudo. A config only root can read is checked with sudo -n when sudo credentials
# are cached, and is otherwise unverified.
status() {
    local installed=false SUDO_CACHED_CACHE=no
    ! sudo_cached || SUDO_CACHED_CACHE=yes
    docker_installed && installed=true
    docker_items
    items_status docker_installed
    ! "$installed" || status_apt_source Docker "$DOCKER_SOURCES" "$(docker_sources)" docker "$(docker_release_url)"
    # The step asks about the group once, and you may say no, so its absence isn't missing
    if in_docker_group; then
        status_item ok "$(id -un) in the docker group"
    else
        status_item info "$(id -un) not in the docker group, which is optional: sudo docker works without it; sudo usermod -aG docker $(id -un) adds you, and is root-equivalent"
    fi
    items_status socket_ready starts_at_boot
    # A config only root can read, or no jq, can't be checked
    if daemon_config_unreadable && ! sudo_ready; then
        status_item unverified "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG (only root can read it; run sudo -v, then status, to check it)"
    elif status_require_cmd jq "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"; then
        items_status daemon_configured
    fi
    items_status docker_auto_updates_configured
    ! "$installed" || status_docker_ports
    ! "$installed" || status_docker_usage
    status_result
}

# Merge the settings into the file, keeping its other keys. Nothing is written until jq succeeds.
# When Docker won't restart with the new file, the old content, kept in memory, goes back, so no
# backup is left in /etc/docker.
configure_daemon() {
    local original="" current='{}' exists=false tmp running=false
    if sudo test -e "$DOCKER_DAEMON_CONFIG"; then
        exists=true
        if ! original="$(sudo cat "$DOCKER_DAEMON_CONFIG")"; then
            echo "  Couldn't read $DOCKER_DAEMON_CONFIG." >&2
            return 1
        fi
        # jq reads an empty file as no input and prints nothing
        [ -z "${original//[[:space:]]/}" ] || current="$original"
    fi
    tmp="$(mktemp)" || return 1
    # A file with several JSON values would come out as several, which dockerd may not reject
    if ! printf '%s\n' "$current" | jq "$DOCKER_DAEMON_SETTINGS" > "$tmp" ||
        [ "$(jq -s length "$tmp" 2>/dev/null)" != 1 ]; then
        rm -f "$tmp"
        echo "  $DOCKER_DAEMON_CONFIG isn't one valid JSON object; fix it and re-run." >&2
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
    # A failed write leaves the old file whole. apply runs this as `configure_daemon || ...`, where
    # set -e is off, so each command checks its own failure.
    if ! install_root_file "$tmp" "$DOCKER_DAEMON_CONFIG"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    # Only a running daemon needs the restart; a stopped one reads the file when it starts
    systemctl is-active --quiet docker.service && running=true
    sudo systemctl try-restart docker.service && return 0
    if "$exists"; then
        if ! write_root_file "$DOCKER_DAEMON_CONFIG" "$original"; then
            echo "  Docker activation failed, and putting the previous configuration back failed too. Write it to" >&2
            echo "  $DOCKER_DAEMON_CONFIG by hand:" >&2
            printf '%s\n' "$original" >&2
            return 1
        fi
        echo "  Docker activation failed; restored the previous configuration. Fix the error and re-run." >&2
    else
        sudo rm -f "$DOCKER_DAEMON_CONFIG" || return 1
        echo "  Docker activation failed; removed the new configuration. Fix the error and re-run." >&2
    fi
    if "$running"; then
        sudo systemctl start docker.service ||
            echo "  Docker couldn't recover with its previous configuration. Check: journalctl -u docker" >&2
    fi
    return 1
}

apply() {
    echo "Setting up Docker..."
    require_cmd jq || return 1
    require_cmd curl || return 1
    # add_apt_repo needs it, after other changes
    require_cmd gpg || return 1

    # Installed Docker updates only while its source is the one this step writes. A release upgrade
    # turns third-party sources off, and a re-run rewrites this one for the new release once Docker
    # publishes packages for it. A fresh install needs those packages for everything else here.
    local installed=false repair_source=false
    docker_installed && installed=true
    if ! "$installed" && ! apt_repo_published Docker "$(docker_release_url)"; then
        return 0
    fi
    if "$installed" && ! docker_source_ok && apt_repo_published Docker "$(docker_release_url)"; then
        repair_source=true
    fi
    local pending=()
    docker_items
    items_pending docker_installed
    ! "$repair_source" ||
        pending+=("Rewrite Docker's apt source for $(ubuntu_codename) ($(apt_source_state "$DOCKER_SOURCES" "$(docker_sources)")): write $DOCKER_SOURCES")
    if "$installed"; then
        items_pending socket_ready daemon_configured starts_at_boot docker_auto_updates_configured
    else
        # Freshly installed packages enable and start both units
        items_pending daemon_configured docker_auto_updates_configured
    fi

    local result=0 fresh=false
    if [ ${#pending[@]} -eq 0 ]; then
        echo "  Docker is already installed and set up."
        return 0
    elif confirm_sudo_changes "${pending[@]}"; then
        # The rest needs Docker's packages, and the docker group they add
        items_apply docker_installed || return 1
        "$installed" || fresh=true
        ! "$repair_source" || add_docker_repo || result=1
        # Each item from here on runs whether or not the one before it failed
        items_apply socket_ready daemon_configured starts_at_boot docker_auto_updates_configured || result=1
        if [ "$result" -ne 0 ]; then
            echo "  Applied the rest. Some changes failed; see the errors above." >&2
        else
            echo "  Applied."
        fi
    fi
    # Asked only once, in the run that installs Docker, whose packages add the group. A no then
    # lasts, and status's info item says how to join later.
    if "$fresh" && ! in_docker_group; then
        add_to_docker_group || result=1
    fi
    return "$result"
}

# The group is root-equivalent, so it gets its own question: Docker works without it, through sudo
# docker. T3 Code's agents need it to run docker.
add_to_docker_group() {
    echo "  The docker group lets docker run without sudo, for you and T3 Code's agents. It's"
    echo "  root-equivalent: anything running as you, agents included, can get root with"
    echo "  docker run -v /:/host. Without it, run sudo docker."
    if ! confirm "  Add $(id -un) to the docker group, with sudo?"; then
        echo "  Left $(id -un) out of the docker group."
        return 0
    fi
    sudo usermod -aG docker "$(id -un)" || return 1
    echo "  Added you to the docker group. New logins get it, but your user services (the T3 Code"
    echo "  service and its agents) and a running tmux server keep their old groups until you"
    echo "  reboot, or run sudo systemctl restart user@\$(id -u), which stops them."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
