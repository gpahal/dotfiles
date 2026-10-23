#!/bin/bash
# shellcheck disable=SC2329 # the step calls the functions this test replaces

# The docker step: a fresh install, its units, the docker group, a source a release upgrade left
# behind, and status's read-only checks of the daemon. test-apt-sources.sh covers add_apt_repo.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=docker-fixture.sh
source "$TESTS_DIR/docker-fixture.sh"
# shellcheck source=diagnostics-fixture.sh
source "$TESTS_DIR/diagnostics-fixture.sh"

command -v jq &>/dev/null || skip "jq isn't installed"
# apt-config stays a sentinel: only the ubuntu step checks the upgrade schedule
load_script docker/install.sh
as_os ubuntu
sandbox_paths docker/install.sh
stub pgrep 'exit 1'
stub_docker_group
stub_dpkg_arch
# install-fails fails the packages' install; update-fails fails the full update
stub_apt_packages --apt-get 'case "$*" in
    *"install -y docker-ce"*) [ ! -e "$SANDBOX/install-fails" ] || exit 100 ;;
    *" update") [ ! -e "$SANDBOX/update-fails" ] || exit 100 ;;
esac'
# Both units start enabled and running
UNITS="$SANDBOX/units"
stub_systemctl_units "$UNITS"
touch "$UNITS"/docker.service.{enabled,active} "$UNITS"/docker.socket.{enabled,active}
# docker prints $SANDBOX/docker-df or docker-ps, and exits with its .status file
stub docker 'case "$1 $2" in
    "system df") out=docker-df ;;
    "ps --format") out=docker-ps ;;
    *) exit 1 ;;
esac
cat "$SANDBOX/$out" 2> /dev/null
exit "$(cat "$SANDBOX/$out.status" 2> /dev/null || echo 0)"'
stub dockerd
stub_sudo_cacheable
# fetch gives the key the step pins
stub_fetch
stub_gpg_fpr "$DOCKER_KEY_FPR"

reset() {
    rm -rf "$SANDBOX/etc/apt" "$SANDBOX/update-fails" "$SANDBOX/install-fails" "$DOCKER_DAEMON_CONFIG"
    mkdir -p "$(dirname "$DOCKER_SOURCES")"
    stub_http_status
    : > "$SANDBOX/installed"
    touch "$SANDBOX/in-group"
    : > "$STUB_LOG"
    answer no
}

# --- a fresh install ---
# Declined: the units aren't listed, since the packages enable them
reset
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_not_contains "$RUN_OUTPUT" "Enable docker.socket"
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was written without a yes"
assert_exit 3 main --status
assert_not_contains "$RUN_OUTPUT" "apt source"

answer yes
assert_exit 0 main
assert_file_contains "$DOCKER_SOURCES" "Signed-By: $DOCKER_KEYRING"
assert_exit 0 main --status

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already installed and set up"
assert_file_not_contains "$STUB_LOG" "sudo"

# A failed install fails the step after what doesn't need the packages
reset
touch "$SANDBOX/install-fails"
answer yes
assert_exit 1 main
assert_eq "$DOCKER_UNATTENDED_CONTENT" "$(cat "$DOCKER_UNATTENDED_CONF")" "the unattended-upgrades origins after a failed install"
[ ! -e "$DOCKER_DAEMON_CONFIG" ] || fail "daemon.json was written without Docker"
assert_file_not_contains "$STUB_LOG" "usermod"

# A failed full update may be another source's fault, so docker.sources stays
reset
touch "$SANDBOX/update-fails"
answer yes
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "it may not be Docker's source"
[ -e "$DOCKER_SOURCES" ] || fail "docker.sources was removed after the full update failed"
assert_file_not_contains "$STUB_LOG" "apt-get install"

# The docker group is root-equivalent, so it gets its own question
reset
rm "$SANDBOX/in-group"
stub usermod 'touch "$SANDBOX/in-group"'
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "install -y docker-ce"
assert_file_contains "$STUB_LOG" "sudo usermod -aG docker me"
reset
rm "$SANDBOX/in-group"
answer yes
wrap_fn confirm 'if [[ "$1" == *"docker group"* ]]; then
    echo "$1 n"
    return 1
fi
real_confirm "$@"'
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "usermod"
restore_fn confirm

# Docker has no packages for this release yet: wait without failing
reset
stub_http_status 404
answer yes
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Docker hasn't published packages for Ubuntu resolute yet"
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was written before Docker published packages for resolute"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_file_not_contains "$STUB_LOG" "usermod"

reset
without_curl() {
    hide curl
    answer yes
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "curl"
    assert_eq "" "$(cat "$STUB_LOG")" "missing curl must fail before external commands"
}
subtest without_curl

# --- installed: the units, and the docker group asked about only by the run that installs Docker ---
reset
docker_set_up
rm "$UNITS"/docker.service.enabled "$UNITS"/docker.socket.{enabled,active}
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now docker.service"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now docker.socket"
assert_file_not_contains "$STUB_LOG" "systemctl disable"
assert_exit 0 main --status
rm "$SANDBOX/in-group"
answer no
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "info       me not in the docker group, which is optional"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_not_contains "$RUN_OUTPUT" "docker group"
rm "$UNITS/docker.service.enabled"
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now docker.service"
assert_not_contains "$RUN_OUTPUT" "docker group"
assert_file_not_contains "$STUB_LOG" "usermod"

# --- installed, with a source for an older release, as a release upgrade leaves it ---
reset
docker_set_up
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Docker's apt source ($DOCKER_SOURCES)"
assert_file_not_contains "$STUB_LOG" "curl"

docker_sources | sed 's/^Suites: .*/Suites: stale-suite/' > "$DOCKER_SOURCES"
snapshot "$DOCKER_SOURCES"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Docker's apt source ($DOCKER_SOURCES): differs from what setup writes; re-run the docker step"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_unchanged "$DOCKER_SOURCES" "when declined"
answer yes
assert_exit 0 main
assert_eq "$(docker_sources)" "$(cat "$DOCKER_SOURCES")" "docker.sources after repairing it"
assert_file_not_contains "$STUB_LOG" "install -y docker-ce"
assert_exit 0 main --status

# No repo for this release yet: nothing can fix it, so the step doesn't fail
reset
docker_set_up
docker_sources | sed 's/^Suites: .*/Suites: stale-suite/' > "$DOCKER_SOURCES"
snapshot "$DOCKER_SOURCES"
stub_http_status 404
answer yes
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Rewrite Docker's apt source"
assert_unchanged "$DOCKER_SOURCES" "before Docker published packages"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Docker's apt source ($DOCKER_SOURCES): differs from what setup writes; Docker hasn't published packages for Ubuntu resolute yet"

# --- status: read-only, sudo -n only when cached, and never starting a stopped daemon ---
reset
docker_set_up
docker_df() {
    printf '%b' "$1" > "$SANDBOX/docker-df"
    echo "${2:-0}" > "$SANDBOX/docker-df.status"
}
docker_df 'Images\t1\t1GB\t0B\n'
# Outside the docker group it goes through sudo -n, only when cached
rm "$SANDBOX/in-group"
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: me isn't in the docker group"
assert_file_not_contains "$STUB_LOG" "docker system"
read_only
cache_sudo yes
assert_exit 0 diag status_docker_usage
assert_file_contains "$STUB_LOG" "sudo -n docker system df --format"
read_only
cache_sudo no
touch "$SANDBOX/in-group"
# docker.socket would start a stopped daemon
rm "$UNITS/docker.service.active"
assert_exit 0 diag status_docker_usage
assert_file_not_contains "$STUB_LOG" "docker system"
touch "$UNITS/docker.service.active"
DOTFILES_STATUS_FOR_ALERTS=1 assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: skipped by --for-alerts"
assert_file_not_contains "$STUB_LOG" "docker system"
read_only
# Ports on every address bypass ufw; 127.0.0.1, other given addresses, and unpublished ports are fine
printf '%b\n' 'web\t0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 127.0.0.1:9000->9000/tcp' \
    'db\t5432/tcp' 'local\t127.0.0.1:3000->3000/tcp, 192.168.1.5:53->53/udp' > "$SANDBOX/docker-ps"
assert_exit 3 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "missing    Container ports published on every address, which ufw doesn't filter: web 0.0.0.0:8080->80/tcp, web [::]:8080->80/tcp;"
assert_file_contains "$STUB_LOG" "docker ps --format {{.Names}}"
printf '%b\n' 'db\t5432/tcp' 'local\t127.0.0.1:3000->3000/tcp' > "$SANDBOX/docker-ps"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
: > "$SANDBOX/docker-ps"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
rm "$SANDBOX/in-group"
: > "$STUB_LOG"
printf '%b\n' 'web\t0.0.0.0:8080->80/tcp' > "$SANDBOX/docker-ps"
cache_sudo yes
assert_exit 3 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "missing    Container ports published on every address, which ufw doesn't filter: web 0.0.0.0:8080->80/tcp"
assert_file_contains "$STUB_LOG" "sudo -n docker ps --format"
read_only
cache_sudo no
touch "$SANDBOX/in-group"
echo 1 > "$SANDBOX/docker-ps.status"
echo 'Error response from daemon: something broke' > "$SANDBOX/docker-ps"
assert_exit 3 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "unknown    Container ports published on every address, which ufw doesn't filter: couldn't list the containers"
rm "$SANDBOX/docker-ps" "$SANDBOX/docker-ps.status"
# Daemon down: no moby shim means no containers; with one, live-restore kept them running
rm "$UNITS/docker.service.active"
stub pgrep '[ "$1" == -f ] && grep -qE -- "$2" "$SANDBOX/shims" 2> /dev/null'
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address, which ufw doesn't filter: the daemon isn't running"
assert_file_not_contains "$STUB_LOG" "docker ps"
# k3s's containerd shim isn't Docker's
echo "/usr/bin/containerd-shim-runc-v2 -namespace k8s.io -id abc -address /run/k3s/containerd/containerd.sock" > "$SANDBOX/shims"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
cp "$STUB_LOG" "$SANDBOX/both.log"
echo "/usr/bin/containerd-shim-runc-v2 -namespace moby -id 032f -address /run/containerd/containerd.sock" >> "$SANDBOX/shims"
assert_exit 3 diag status_docker_ports
cat "$STUB_LOG" >> "$SANDBOX/both.log"
assert_contains "$RUN_OUTPUT" "unknown    Container ports published on every address, which ufw doesn't filter: containers are running while the Docker daemon is down"
assert_file_not_contains "$SANDBOX/both.log" "docker ps"
touch "$UNITS/docker.service.active"
rm "$SANDBOX/shims"
stub pgrep 'exit 1'
read_only
run status
assert_contains "$RUN_OUTPUT" "Docker disk usage"
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
read_only
DOTFILES_STATUS_FOR_ALERTS=1 run status
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: skipped by --for-alerts"
read_only
: > "$SANDBOX/installed"
run status
assert_not_contains "$RUN_OUTPUT" "Docker disk usage"
read_only
test_done
