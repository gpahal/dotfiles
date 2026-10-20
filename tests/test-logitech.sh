#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# test-docker-sources.sh covers add_apt_repo's failures.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script logitech/install.sh
export SANDBOX
as_os ubuntu

SOLAAR_SOURCES="$SANDBOX/apt/sources.list.d/solaar.sources"
SOLAAR_PIN="$SANDBOX/apt/preferences.d/dotfiles-solaar"
SOLAAR_KEYRING="$SANDBOX/keyrings/solaar.asc"
OS_RELEASE="$SANDBOX/os-release"
echo "VERSION_CODENAME=resolute" > "$OS_RELEASE"

# The version file holds the installed Solaar's; the PPA's is installed once its source is there
stub dpkg-query 'v="$SANDBOX/solaar-version"
[ -e "$v" ] || exit 1
case "$*" in
    *Status*) printf "install ok installed" ;;
    *Version*) printf "%s" "$(cat "$v")" ;;
esac'
stub apt-get '[ -z "${APT_FAILS:-}" ] || exit 100
[ -z "${UPDATE_FAILS:-}" ] || [ "${*: -1}" != update ] || exit 100
if [ "${*: -1}" == solaar ]; then
    if [ -e "$SANDBOX/apt/sources.list.d/solaar.sources" ]; then
        echo "1.1.20+202607061356~ubuntu26.04.1" > "$SANDBOX/solaar-version"
    else
        echo "1.1.19-1" > "$SANDBOX/solaar-version"
    fi
fi'
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0
stub_sudo_exec
# fetch gives the key the step pins
replace_fn fetch 'echo key > "$2"'
stub gpg "printf 'pub:-\\nfpr:::::::::%s:\\n' $SOLAAR_KEY_FPR"
stub curl 'cat "$SANDBOX/http-status"'
echo 200 > "$SANDBOX/http-status"
mkdir -p "$(dirname "$SOLAAR_SOURCES")"

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Only Solaar taken from the Solaar team's PPA"
assert_contains "$RUN_OUTPUT" "missing    The Solaar team's PPA's apt source ($SOLAAR_SOURCES): missing"
assert_contains "$RUN_OUTPUT" "missing    Solaar 1.1.20 or later; older ones fail"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install Solaar from the Solaar team's PPA"
assert_file_not_contains "$STUB_LOG" "apt-get"
[ ! -e "$SOLAAR_PIN" ] && [ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added though confirm declined"

export DOTFILES_ASSUME_YES=1 APT_FAILS=1
assert_exit 1 main
[ ! -e "$SANDBOX/solaar-version" ] || fail "Solaar counts as installed after a failed install"
[ ! -e "$SOLAAR_SOURCES" ] || fail "a source apt-get update failed on was kept"
[ -e "$SOLAAR_PIN" ] || fail "the pin wasn't written"

export APT_FAILS="" UPDATE_FAILS=1
: > "$STUB_LOG"
assert_exit 1 main
assert_file_not_contains "$STUB_LOG" "install -y solaar"
export UPDATE_FAILS=""

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installed Solaar 1.1.20."
assert_file_contains "$STUB_LOG" "install -y solaar"
assert_eq "Types: deb
URIs: https://ppa.launchpadcontent.net/solaar-unifying/stable/ubuntu
Suites: resolute
Components: main
Signed-By: $SOLAAR_KEYRING" "$(cat "$SOLAAR_SOURCES")" "the PPA's source"
assert_file_contains "$SOLAAR_PIN" "Pin: release o=LP-PPA-solaar-unifying-stable"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Solaar 1.1.20 or later"
assert_contains "$RUN_OUTPUT" "ok         The Solaar team's PPA's apt source"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Solaar 1.1.20 is already installed."
assert_file_not_contains "$STUB_LOG" "sudo"

# Ubuntu's older Solaar is upgraded from the PPA
echo "1.1.19-1" > "$SANDBOX/solaar-version"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Solaar 1.1.20 or later"
assert_exit 0 main
assert_eq "1.1.20+202607061356~ubuntu26.04.1" "$(cat "$SANDBOX/solaar-version")" "the version after upgrading"

# Before the PPA publishes for a new release, Ubuntu's Solaar stands in, and the next run adds it
echo "VERSION_CODENAME=stonking" > "$OS_RELEASE"
echo 404 > "$SANDBOX/http-status"
rm -f "$SOLAAR_SOURCES" "$SANDBOX/solaar-version"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "hasn't published packages for Ubuntu stonking yet"
assert_eq "1.1.19-1" "$(cat "$SANDBOX/solaar-version")" "the version without the PPA"
[ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added before it published for this release"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sudo"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "hasn't published packages for Ubuntu stonking yet"
test_done
