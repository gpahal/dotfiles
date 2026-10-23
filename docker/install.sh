#!/bin/bash
set -euo pipefail

# Install Docker Engine from Docker's apt repo, started at boot.
# Changes the system with sudo whatever HOME is: test it in an Ubuntu VM with systemd.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/systemd.sh
source "$DOTFILES_DIR/lib/systemd.sh"

STEP_OS=ubuntu
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
DOCKER_REPO=https://download.docker.com/linux/ubuntu
DOCKER_KEY_URL="$DOCKER_REPO/gpg"
# The key's UID: "Docker Release (CE deb)"
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
# Origin and label from https://download.docker.com/linux/ubuntu/dists/<codename>/Release
DOCKER_UNATTENDED_CONF=/etc/apt/apt.conf.d/52dotfiles-docker
DOCKER_UNATTENDED_CONTENT='// From the dotfiles docker step: install Docker updates with the daily security updates
Unattended-Upgrade::Origins-Pattern { "origin=Docker,label=Docker CE"; };'
DOCKER_DAEMON_CONFIG=/etc/docker/daemon.json
DOCKER_DAEMON_KEYS="log-driver, live-restore, localhost-only published ports, and address pools"
# Published ports bypass ufw, so bind them to 127.0.0.1. The default pools reach 192.168.0.0/16,
# which ufw lets SSH in from; /24s so a Compose project per worktree doesn't exhaust them.
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
    apt_installed "${DOCKER_PACKAGES[@]}"
}

# Cached through a memo scope, such as one status run
docker_active() {
    memo DOCKER_ACTIVE unit_active docker.service
}

docker_auto_updates_configured() {
    file_is "$DOCKER_UNATTENDED_CONF" "$DOCKER_UNATTENDED_CONTENT"
}

docker_sources() {
    deb822_source "$DOCKER_REPO" stable "$DOCKER_KEYRING" "$(dpkg --print-architecture)"
}

docker_source_ok() {
    file_is "$DOCKER_SOURCES" "$(docker_sources)"
}

add_docker_repo() {
    add_apt_repo Docker "$DOCKER_SOURCES" "$(docker_sources)" "$DOCKER_KEY_URL" "$DOCKER_KEYRING" "$DOCKER_KEY_FPR"
}

# Runs where set -e is off: each command checks its own failure.
install_docker() {
    add_docker_repo || return 1
    if ! apt_get_update; then
        echo "  apt-get update failed; it may not be Docker's source. Fix the error above and re-run." >&2
        return 1
    fi
    apt_get install -y "${DOCKER_PACKAGES[@]}"
}

# Reads the group database, not this process's groups, so it's true before a new login
in_docker_group() {
    case " $(id -nG "$(id -un)") " in *" docker "*) ;; *) return 1 ;; esac
}

starts_at_boot() {
    unit_enabled docker.service
}

socket_ready() {
    unit_on docker.socket
}

# docker_items [repair]: repair adds apply's rewrite of Docker's apt source. Order matters: the
# daemon config goes before enabling the service, so it isn't restarted for it.
docker_items() {
    local daemon_pending="Rotate container logs, keep containers up across daemon restarts, publish ports on 127.0.0.1 unless given an address, and give new networks /24s outside 192.168.0.0/16: set $DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"
    daemon_config_unreadable && daemon_pending="Check $DOCKER_DAEMON_CONFIG and set $DOCKER_DAEMON_KEYS in it"
    items_reset
    item --sudo "Docker Engine from Docker's apt repo" "Install ${DOCKER_PACKAGES[*]} from Docker's apt repo" \
        docker_installed install_docker
    [ "${1:-}" != repair ] ||
        item --sudo "" "Rewrite Docker's apt source for $(ubuntu_codename) ($(apt_source_state "$DOCKER_SOURCES" "$(docker_sources)")): write $DOCKER_SOURCES" \
            docker_source_ok add_docker_repo
    item --sudo "docker.socket enabled and listening" "Enable docker.socket" socket_ready "enable_units_now docker.socket"
    item --sudo "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG" "$daemon_pending$(daemon_restart_note)" \
        daemon_configured configure_installed_daemon
    item --sudo "Docker starts at boot (docker.service enabled)" \
        "Start Docker at boot, so containers with a restart policy come back: enable docker.service" \
        starts_at_boot "enable_units_now docker.service"
    item --sudo "Docker origins allowed in unattended-upgrades ($DOCKER_UNATTENDED_CONF)" \
        "Let unattended-upgrades install Docker updates: write $DOCKER_UNATTENDED_CONF" \
        docker_auto_updates_configured "write_root_content DOCKER_UNATTENDED_CONF DOCKER_UNATTENDED_CONTENT"
}

# After a failed install there's no dockerd to check the config with
configure_installed_daemon() {
    docker_installed && configure_daemon
}

daemon_config_unreadable() {
    [ -e "$DOCKER_DAEMON_CONFIG" ] && [ ! -r "$DOCKER_DAEMON_CONFIG" ]
}

daemon_configured() {
    read_root_file "$DOCKER_DAEMON_CONFIG" -n | json_applied - "$DOCKER_DAEMON_SETTINGS"
}

daemon_restart_note() {
    docker_active || return 0
    printf '%s' ". This restarts the running daemon, which stops running containers unless"
    printf '%s' " live-restore was already on; only those with a restart policy come back. The port"
    printf '%s' " binding applies to the default bridge, and to networks created from now on"
}

# Sets DOCKER_OUT and DOCKER_STATUS, which the caller declares local. Returns 0 on success, 1 when
# it already reported why docker couldn't be asked, 2 for another failure the caller reports.
docker_status_run() {
    local label="$1" docker=(docker)
    shift
    DOCKER_OUT=""
    DOCKER_STATUS=0
    if ! in_docker_group; then
        if ! sudo_ready; then
            status_needs_root "$label:" "$(id -un) isn't in the docker group"
            return 1
        fi
        docker=(sudo -n docker)
    fi
    DOCKER_OUT="$(run_bounded 30 "${docker[@]}" "$@" 2>&1)" || DOCKER_STATUS=$?
    [ "$DOCKER_STATUS" -ne 0 ] || return 0
    case "$DOCKER_OUT" in
        # Joined the group after this session started
        *"permission denied"*)
            status_item unverified "$label: $(id -un) can't reach the daemon's socket yet; log out and back in, so the docker group applies, then check it"
            ;;
        *"Cannot connect to the Docker daemon"* | *"Is the docker daemon running"*)
            status_item info "$label: the daemon isn't running"
            ;;
        *) return 2 ;;
    esac
    return 1
}

# Only asks a running daemon: docker.socket would start a stopped one.
status_docker_usage() {
    local label="Docker disk usage" out status=0 type count size reclaimable summary="" DOCKER_OUT DOCKER_STATUS
    if status_for_alerts; then
        status_item unverified "$label: skipped by --for-alerts"
        return 0
    fi
    if ! docker_active; then
        status_item info "$label: the daemon isn't running, and status doesn't start it"
        return 0
    fi
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

# Docker lists IPv4 as 0.0.0.0:<port> and IPv6 as [::]:<port>
ports_on_every_address() {
    local nl=$'\n'
    printf '%s\n' "${1//, /$nl}" | grep -E '^(0\.0\.0\.0|\[::\]):[^ ]*->' || true
}

# A stopped daemon isn't asked (docker.socket would start it), but live-restore containers keep
# running under shims in the moby namespace. [m] stops pgrep matching its own shell.
status_docker_ports() {
    local label="Container ports published on every address, which ufw doesn't filter"
    local none="No container ports published on every address, which ufw doesn't filter"
    local out status=0 name ports open="" port DOCKER_OUT DOCKER_STATUS
    if ! docker_active; then
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

# Never asks for sudo; uses sudo -n only when credentials are cached.
status() {
    local installed=false MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    sudo_ready || true
    # Here, since docker_items first asks inside a $( ), which would keep the answer to itself
    docker_active || true
    docker_installed && installed=true
    docker_items
    items_status docker_installed
    ! "$installed" || status_apt_source Docker "$DOCKER_SOURCES" "$(docker_sources)" docker "$(apt_release_url "$DOCKER_REPO")"
    # Optional: apply asks once and a no lasts
    if in_docker_group; then
        status_item ok "$(id -un) in the docker group"
    else
        status_item info "$(id -un) not in the docker group, which is optional: sudo docker works without it; sudo usermod -aG docker $(id -un) adds you, and is root-equivalent"
    fi
    items_status socket_ready starts_at_boot
    if daemon_config_unreadable && ! sudo_ready; then
        status_needs_root "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG" "only root can read it"
    elif status_require_cmd jq "$DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"; then
        items_status daemon_configured
    fi
    items_status docker_auto_updates_configured
    ! "$installed" || status_docker_ports
    ! "$installed" || status_docker_usage
}

# Runs where set -e is off. Rolls back from memory if Docker won't restart, so no backup is left
# in /etc/docker.
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
    # Several JSON values would come out as several, which dockerd may not reject
    if ! printf '%s\n' "$current" | jq "$DOCKER_DAEMON_SETTINGS" > "$tmp" ||
        [ "$(jq -s length "$tmp" 2>/dev/null)" != 1 ]; then
        rm -f "$tmp"
        echo "  $DOCKER_DAEMON_CONFIG isn't one valid JSON object; fix it and re-run." >&2
        return 1
    fi
    if json_applied - "$DOCKER_DAEMON_SETTINGS" <<< "$current"; then
        rm -f "$tmp"
        echo "  $DOCKER_DAEMON_CONFIG already sets $DOCKER_DAEMON_KEYS."
        return 0
    fi
    if ! sudo dockerd --validate --config-file "$tmp"; then
        rm -f "$tmp"
        echo "  Docker rejected the proposed configuration; $DOCKER_DAEMON_CONFIG is unchanged." >&2
        return 1
    fi
    if ! install_root_file "$tmp" "$DOCKER_DAEMON_CONFIG"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    unit_active docker.service && running=true
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
    # add_apt_repo needs it; fail before changing anything
    require_cmd gpg || return 1

    # A release upgrade disables the source; rewrite it once Docker publishes for the new release.
    local installed=false repair="" result=0 fresh=false
    docker_installed && installed=true
    if ! "$installed" && ! apt_repo_published Docker "$(apt_release_url "$DOCKER_REPO")"; then
        return 0
    fi
    if "$installed" && ! docker_source_ok && apt_repo_published Docker "$(apt_release_url "$DOCKER_REPO")"; then
        repair=repair
    fi
    docker_items "$repair"
    if "$installed"; then
        items_apply_confirmed --done "  Docker is already installed and set up." || result=1
        return "$result"
    fi
    # Fresh packages enable and start both units, so they're left out of the list, and checked only
    # once the packages are in
    items_apply_confirmed docker_installed daemon_configured docker_auto_updates_configured || result=1
    if docker_installed; then
        fresh=true
        items_apply_confirmed socket_ready starts_at_boot || result=1
    fi
    # Asked only in the run that installs Docker, so a no lasts
    if "$fresh" && ! in_docker_group; then
        add_to_docker_group || result=1
    fi
    return "$result"
}

# Root-equivalent, so it gets its own question
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
