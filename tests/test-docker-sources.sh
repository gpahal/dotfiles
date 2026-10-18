#!/bin/bash
set -euo pipefail
# os: ubuntu

# The docker step writes Docker's own source, rolling it back when apt can't use it, and lets
# unattended-upgrades install Docker's updates. With Docker installed, it rewrites a source for an
# older release. Until Docker publishes packages for this release, it waits without failing.
# test-apt-sources.sh covers the other states apt_source_state reports, and a failed key download.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# apt-config stays a sentinel: only the ubuntu step checks the daily upgrade schedule
load_script docker/install.sh
# No containerd shim runs, so a stopped daemon runs no containers
stub pgrep 'exit 1'
is_macos() { false; }
is_ubuntu() { true; }

DOCKER_SOURCES="$SANDBOX/apt/sources.list.d/docker.sources"
DOCKER_UNATTENDED_CONF="$SANDBOX/apt/52dotfiles-docker"
DOCKER_DAEMON_CONFIG="$SANDBOX/daemon.json"
OS_RELEASE="$SANDBOX/os-release"

# Packages listed in $SANDBOX/installed are installed. Installing Docker's adds them.
stub dpkg-query 'grep -qxF "${!#}" "'"$SANDBOX"'/installed" && echo "install ok installed"'
stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
# An update from Docker's source alone fails when $SANDBOX/docker-update-fails exists, and a full
# update when $SANDBOX/update-fails does. With $SANDBOX/lists-locked, the first fails the way
# apt-get update does while another one runs. With $SANDBOX/docker-locked-once or
# $SANDBOX/full-locked-once, the next update of that kind fails that way, and the lock is then free.
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
# fetch downloads Docker's key, which has the fingerprint the step pins
fetch() { echo key > "$2"; }
stub gpg "printf 'pub:-\\nfpr:::::::::%s:\\n' $DOCKER_KEY_FPR"
# The key goes under /etc/apt/keyrings
DOCKER_KEYRING="$SANDBOX/keyrings/docker.asc"
# curl answers the HEAD request for Docker's Release file with $SANDBOX/http-status
stub curl 'cat "'"$SANDBOX"'/http-status"'

reset() {
    rm -rf "$SANDBOX/apt" "$SANDBOX/update-fails" "$SANDBOX/docker-update-fails" "$DOCKER_DAEMON_CONFIG"
    mkdir -p "$(dirname "$DOCKER_SOURCES")"
    echo 200 > "$SANDBOX/http-status"
    : > "$SANDBOX/installed"
    : > "$STUB_LOG"
    unset DOTFILES_ASSUME_YES
}

# Declined: nothing written
reset
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was written without a yes"

# On a yes, Docker's own source is written, with unattended-upgrades set up
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$DOCKER_SOURCES" "Signed-By: $DOCKER_KEYRING"
assert_file_contains "$DOCKER_UNATTENDED_CONF" '"origin=Docker,label=Docker CE";'
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Docker origins allowed in unattended-upgrades"

# Re-run: nothing to do
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already installed and set up"
assert_file_not_contains "$STUB_LOG" "sudo"

# Docker's source alone fails to update right after the step writes it: it's removed, and the
# step fails
reset
touch "$SANDBOX/docker-update-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 update --error-on=any -o Dir::Etc::sourcelist=$DOCKER_SOURCES -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0"
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was kept after its update failed"
assert_file_not_contains "$STUB_LOG" "apt-get install"

# The same with a docker.sources and a key from before: both come back as they were
reset
mkdir -p "$(dirname "$DOCKER_KEYRING")"
echo "old key" > "$DOCKER_KEYRING"
echo "old source" > "$DOCKER_SOURCES"
touch "$SANDBOX/docker-update-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "so the old one is back"
assert_eq "old source" "$(cat "$DOCKER_SOURCES")" "docker.sources after its update failed"
assert_eq "old key" "$(cat "$DOCKER_KEYRING")" "Docker's key after the update failed"
# Without a key from before, the new one goes too
reset
rm -f "$DOCKER_KEYRING"
touch "$SANDBOX/docker-update-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
[ ! -e "$DOCKER_KEYRING" ] || fail "Docker's new key was kept after its source's update failed"
# Writing the key fails partway: the old key stays whole, with no temp file beside it, and no
# source is written
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
# Writing the source fails: the old key comes back, the old source stays, or none is left when
# there was none, and the step fails
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

# Writing the source fails every time, so putting the old one back fails too: the step says so
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

# A docker.sources that can't be read fails the step before it touches the key
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

# Another apt-get update holds the lists lock: docker.sources stays, since Docker's source isn't
# at fault, and the step fails
reset
touch "$SANDBOX/lists-locked"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Another apt-get update holds apt's lock"
[ -e "$DOCKER_SOURCES" ] || fail "docker.sources was removed while another update held the lock"
assert_file_not_contains "$STUB_LOG" "apt-get install"
rm "$SANDBOX/lists-locked"

# Another update holds the lock for a moment, during either update: the step waits it out
for update in docker full; do
    reset
    touch "$SANDBOX/$update-locked-once"
    export DOTFILES_ASSUME_YES=1
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "apt's lists lock is held"
    assert_file_contains "$STUB_LOG" "install -y docker-ce"
done

# Docker's source updates, but the full update fails: another source may be at fault, so
# docker.sources stays, and the step fails
reset
touch "$SANDBOX/update-fails"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "it may not be Docker's source"
[ -e "$DOCKER_SOURCES" ] || fail "docker.sources was removed after the full update failed"
assert_file_not_contains "$STUB_LOG" "apt-get install"

# Both updates succeed, and the install waits for dpkg's lock
reset
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce"

# Docker has no packages for this release yet: a fresh install says so, and waits without failing
# or changing anything
reset
echo 404 > "$SANDBOX/http-status"
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Docker hasn't published packages for Ubuntu resolute yet; re-run this step later."
[ ! -e "$DOCKER_SOURCES" ] || fail "docker.sources was written before Docker published packages for resolute"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_file_not_contains "$STUB_LOG" "usermod"

# --- Docker installed, and its source for an older release, as a release upgrade leaves it. The
# step rewrites the source, unless Docker has no repo for this release yet. ---
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
# Declined: nothing written
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Rewrite Docker's apt source for resolute"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_exit 0 cmp -s "$SANDBOX/before" "$DOCKER_SOURCES"
# Approved: rewritten, checked with an update from it alone, and then ok
export DOTFILES_ASSUME_YES=1
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "$(docker_sources)" "$(cat "$DOCKER_SOURCES")" "docker.sources after repairing it"
assert_file_contains "$STUB_LOG" "update --error-on=any -o Dir::Etc::sourcelist=$DOCKER_SOURCES"
assert_file_not_contains "$STUB_LOG" "install -y docker-ce"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Docker's apt source ($DOCKER_SOURCES)"

# Docker has no repo for this release yet: the source stays as it is, and the step says so without
# listing the rewrite it can't do. Nothing here can fix that, so the step doesn't fail, and status
# says what it waits for.
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

# Missing curl fails the step before it runs anything
reset
export DOTFILES_ASSUME_YES=1
hide curl
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "curl"
assert_eq "" "$(cat "$STUB_LOG")" "missing curl must fail before external commands"
test_done
