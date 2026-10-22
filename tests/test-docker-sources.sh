#!/bin/bash
set -euo pipefail

# test-apt-sources.sh covers apt_source_state's other states and a failed key download.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# apt-config stays a sentinel: only the ubuntu step checks the upgrade schedule
load_script docker/install.sh
stub pgrep 'exit 1'
as_os ubuntu

DOCKER_SOURCES="$SANDBOX/apt/sources.list.d/docker.sources"
DOCKER_UNATTENDED_CONF="$SANDBOX/apt/52dotfiles-docker"
DOCKER_DAEMON_CONFIG="$SANDBOX/daemon.json"
OS_RELEASE="$SANDBOX/os-release"

stub dpkg-query 'grep -qxF "${!#}" "'"$SANDBOX"'/installed" && echo "install ok installed"'
stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
# Flag files in $SANDBOX make updates fail; lists-locked fails as a concurrent apt-get update does
stub apt-get 'S="'"$SANDBOX"'"
locked() {
    echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 6 (apt-get)" >&2
    exit 100
}
case "$*" in
    *"install -y docker-ce"*) printf "%s\n" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$S/installed" ;;
    *" update --error-on=any "*)
        [ ! -e "$S/lists-locked" ] || locked
        ! rm "$S/docker-locked-once" 2> /dev/null || locked
        [ ! -e "$S/docker-update-fails" ] || exit 100 ;;
    *" update")
        ! rm "$S/full-locked-once" 2> /dev/null || locked
        [ ! -e "$S/update-fails" ] || exit 100 ;;
esac'
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0
stub id 'case "$1" in -un) echo me ;; -nG) echo "me docker" ;; esac'
stub systemctl 'case "$*" in *docker.socket* | "is-enabled --quiet docker.service" | try-restart*) exit 0 ;; *) exit 1 ;; esac'
stub dockerd
stub_sudo_exec
# fetch gives the key the step pins
replace_fn fetch 'echo key > "$2"'
stub gpg "printf 'pub:-\\nfpr:::::::::%s:\\n' $DOCKER_KEY_FPR"
DOCKER_KEYRING="$SANDBOX/keyrings/docker.asc"
stub curl 'cat "'"$SANDBOX"'/http-status"'

reset() {
    rm -rf "$SANDBOX/apt" "$SANDBOX/update-fails" "$SANDBOX/docker-update-fails" "$DOCKER_DAEMON_CONFIG"
    mkdir -p "$(dirname "$DOCKER_SOURCES")"
    echo 200 > "$SANDBOX/http-status"
    : > "$SANDBOX/installed"
    : > "$STUB_LOG"
    unset DOTFILES_ASSUME_YES
}

# Declined: the units aren't listed, since the packages enable them
reset
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "    - Install docker-ce docker-ce-cli"
assert_contains "$RUN_OUTPUT" "set $DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"
assert_contains "$RUN_OUTPUT" "Let unattended-upgrades install Docker updates"
assert_not_contains "$RUN_OUTPUT" "Enable docker.socket"
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was written without a yes"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Docker Engine from Docker's apt repo"
assert_contains "$RUN_OUTPUT" "missing    $DOCKER_DAEMON_KEYS in $DOCKER_DAEMON_CONFIG"
assert_not_contains "$RUN_OUTPUT" "apt source"

export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$DOCKER_SOURCES" "Signed-By: $DOCKER_KEYRING"
assert_file_contains "$DOCKER_UNATTENDED_CONF" '"origin=Docker,label=Docker CE";'
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Docker origins allowed in unattended-upgrades"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already installed and set up"
assert_file_not_contains "$STUB_LOG" "sudo"

# Docker's source fails its first update: it's removed
reset
touch "$SANDBOX/docker-update-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 update --error-on=any -o Dir::Etc::sourcelist=$DOCKER_SOURCES -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0"
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was kept after its update failed"
assert_file_not_contains "$STUB_LOG" "apt-get install"

# Without an old key, the new one goes too
reset
rm -f "$DOCKER_KEYRING"
touch "$SANDBOX/docker-update-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
[ ! -e "$DOCKER_KEYRING" ] || fail "Docker's new key was kept after its source's update failed"
mkdir -p "$(dirname "$DOCKER_KEYRING")"
reset
echo "old key" > "$DOCKER_KEYRING"
stub install 'dest="${!#}"
if [ -e "'"$SANDBOX"'/install-key-fails" ] && [[ "${dest##*/}" == .docker.asc.* ]]; then
    echo "ne" > "$dest"
    exit 1
fi
exec /usr/bin/install "$@"'
touch "$SANDBOX/install-key-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
rm "$SANDBOX/install-key-fails" "$STUB_DIR/install"
assert_eq "old key" "$(cat "$DOCKER_KEYRING")" "Docker's key after writing it failed partway"
assert_eq docker.asc "$(/bin/ls -A "$(dirname "$DOCKER_KEYRING")")" "files beside Docker's key after writing it failed"
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was written after the key failed"
stub mv 'if [ "${!#}" = "'"$DOCKER_SOURCES"'" ] && rm "'"$SANDBOX"'/mv-fails-once" 2> /dev/null; then
    exit 1
fi
exec /bin/mv "$@"'
for before in source none; do
    reset
    echo "old key" > "$DOCKER_KEYRING"
    [ "$before" != source ] || echo "old source" > "$DOCKER_SOURCES"
    touch "$SANDBOX/mv-fails-once"
    export DOTFILES_ASSUME_YES=1
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "Writing $DOCKER_SOURCES failed"
    assert_eq "old key" "$(cat "$DOCKER_KEYRING")" "Docker's key after writing the source failed ($before before)"
    if [ "$before" = source ]; then
        assert_eq "old source" "$(cat "$DOCKER_SOURCES")" "docker.sources after writing it failed"
    else
        [ ! -e "$DOCKER_SOURCES" ] || fail "a docker.sources was kept after writing it failed"
    fi
    assert_eq "$([ "$before" != source ] || echo docker.sources)" "$(/bin/ls -A "$(dirname "$DOCKER_SOURCES")")" \
        "files beside docker.sources after writing it failed ($before before)"
    assert_file_not_contains "$STUB_LOG" "apt-get"
done

stub mv '[ "${!#}" != "'"$DOCKER_SOURCES"'" ] || exit 1
exec /bin/mv "$@"'
reset
echo "old key" > "$DOCKER_KEYRING"
echo "old source" > "$DOCKER_SOURCES"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Writing $DOCKER_SOURCES failed, and putting the old one back failed too"
assert_not_contains "$RUN_OUTPUT" "so the old one is back"
rm "$STUB_DIR/mv"

reset
echo "old key" > "$DOCKER_KEYRING"
echo "old source" > "$DOCKER_SOURCES"
chmod 000 "$DOCKER_SOURCES"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
chmod 644 "$DOCKER_SOURCES"
assert_eq "old key" "$(cat "$DOCKER_KEYRING")" "Docker's key when docker.sources can't be read"
assert_eq "old source" "$(cat "$DOCKER_SOURCES")" "an unreadable docker.sources"
assert_file_not_contains "$STUB_LOG" "apt-get"

# A lists lock isn't Docker's fault, so docker.sources stays
reset
touch "$SANDBOX/lists-locked"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Another apt-get update holds apt's lock"
[ -e "$DOCKER_SOURCES" ] || fail "docker.sources was removed while another update held the lock"
assert_file_not_contains "$STUB_LOG" "apt-get install"
rm "$SANDBOX/lists-locked"

for update in docker full; do
    reset
    touch "$SANDBOX/$update-locked-once"
    export DOTFILES_ASSUME_YES=1
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "apt's lists lock is held"
    assert_file_contains "$STUB_LOG" "install -y docker-ce"
done

# A failed full update may be another source's fault, so docker.sources stays
reset
touch "$SANDBOX/update-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "it may not be Docker's source"
[ -e "$DOCKER_SOURCES" ] || fail "docker.sources was removed after the full update failed"
assert_file_not_contains "$STUB_LOG" "apt-get install"

# The docker group is root-equivalent, so it gets its own question
reset
stub id 'case "$1" in -un) echo me ;; -nG) [ -e "'"$SANDBOX"'/in-group" ] && echo "me docker" || echo me ;; esac'
stub usermod 'touch "'"$SANDBOX"'/in-group"'
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce"
assert_contains "$RUN_OUTPUT" "root-equivalent"
assert_file_contains "$STUB_LOG" "sudo usermod -aG docker me"
assert_contains "$RUN_OUTPUT" "Added you to the docker group."
reset
rm "$SANDBOX/in-group"
wrap_fn confirm 'if [[ "$1" == *"docker group"* ]]; then
    echo "$1 n"
    return 1
fi
real_confirm "$@"'
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left me out of the docker group."
assert_file_not_contains "$STUB_LOG" "usermod"
restore_fn confirm
stub id 'case "$1" in -un) echo me ;; -nG) echo "me docker" ;; esac'

# Docker has no packages for this release yet: wait without failing
reset
echo 404 > "$SANDBOX/http-status"
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Docker hasn't published packages for Ubuntu resolute yet; re-run this step later."
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was written before Docker published packages for resolute"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_file_not_contains "$STUB_LOG" "usermod"

# --- Docker installed, with a source for an older release, as a release upgrade leaves it ---
set_up_docker() {
    reset
    printf '%s\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > "$SANDBOX/installed"
    jq "$DOCKER_DAEMON_SETTINGS" <<< '{}' > "$DOCKER_DAEMON_CONFIG"
    printf '%s\n' "$DOCKER_UNATTENDED_CONTENT" > "$DOCKER_UNATTENDED_CONF"
    docker_sources > "$DOCKER_SOURCES"
}
set_up_docker
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Docker's apt source ($DOCKER_SOURCES)"
assert_file_not_contains "$STUB_LOG" "curl"

set_up_docker
docker_sources | sed 's/^Suites: .*/Suites: stale-suite/' > "$DOCKER_SOURCES"
cp "$DOCKER_SOURCES" "$SANDBOX/before"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Docker's apt source ($DOCKER_SOURCES): differs from what setup writes; re-run the docker step"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Rewrite Docker's apt source for resolute"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_exit 0 cmp -s "$SANDBOX/before" "$DOCKER_SOURCES"
export DOTFILES_ASSUME_YES=1
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "$(docker_sources)" "$(cat "$DOCKER_SOURCES")" "docker.sources after repairing it"
assert_file_contains "$STUB_LOG" "update --error-on=any -o Dir::Etc::sourcelist=$DOCKER_SOURCES"
assert_file_not_contains "$STUB_LOG" "install -y docker-ce"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Docker's apt source ($DOCKER_SOURCES)"

# No repo for this release yet: nothing can fix it, so the step doesn't fail
set_up_docker
docker_sources | sed 's/^Suites: .*/Suites: stale-suite/' > "$DOCKER_SOURCES"
cp "$DOCKER_SOURCES" "$SANDBOX/before"
echo 404 > "$SANDBOX/http-status"
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Docker hasn't published packages for Ubuntu resolute yet; re-run this step later."
assert_not_contains "$RUN_OUTPUT" "Rewrite Docker's apt source"
assert_exit 0 cmp -s "$SANDBOX/before" "$DOCKER_SOURCES"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Docker's apt source ($DOCKER_SOURCES): differs from what setup writes; Docker hasn't published packages for Ubuntu resolute yet"

reset
export DOTFILES_ASSUME_YES=1
hide curl
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "curl"
assert_eq "" "$(cat "$STUB_LOG")" "missing curl must fail before external commands"
test_done
