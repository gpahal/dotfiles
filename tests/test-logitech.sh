#!/bin/bash
# shellcheck disable=SC2329

# Solaar from its team's pinned PPA. test-apt-sources.sh covers add_apt_repo's failures.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script logitech/install.sh
sandbox_paths logitech/install.sh
as_os ubuntu

OS_RELEASE="$SANDBOX/os-release"
echo "VERSION_CODENAME=resolute" > "$OS_RELEASE"

# The version file holds the installed Solaar's; the PPA's is installed once its source is there
stub dpkg-query 'v="$SANDBOX/solaar-version"
[ -e "$v" ] || exit 1
case "$*" in
    *Status*) printf "install ok installed" ;;
    *Version*) printf "%s" "$(cat "$v")" ;;
esac'
stub apt-get 'if [ "${*: -1}" == solaar ]; then
    if [ -e "$SANDBOX/etc/apt/sources.list.d/solaar.sources" ]; then
        echo "1.1.20+202607061356~ubuntu26.04.1" > "$SANDBOX/solaar-version"
    else
        echo "1.1.19-1" > "$SANDBOX/solaar-version"
    fi
fi'
stub_sudo_exec
# fetch gives the key the step pins
stub_fetch
stub_gpg_fpr "$SOLAAR_KEY_FPR"
stub_http_status
mkdir -p "$(dirname "$SOLAAR_SOURCES")"

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Only Solaar taken from the Solaar team's PPA"
assert_contains "$RUN_OUTPUT" "missing    The Solaar team's PPA's apt source ($SOLAAR_SOURCES): missing"
assert_contains "$RUN_OUTPUT" "missing    Solaar 1.1.20 or later; older ones fail"

# Adding the PPA needs gpg, so without it the step changes nothing
hide gpg
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "gpg"
[ ! -e "$SOLAAR_PIN" ] || fail "the pin was written without gpg"
stub_gpg_fpr "$SOLAAR_KEY_FPR"

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install Solaar from the Solaar team's PPA"
assert_file_not_contains "$STUB_LOG" "apt-get"
[ ! -e "$SOLAAR_PIN" ] && [ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added though confirm declined"

# Without the pin, apt would take any package from the PPA, so a failed pin stops it being added or used
answer yes
mkdir -p "$SOLAAR_PIN"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$SOLAAR_PIN isn't in place, so the Solaar team's PPA wasn't added."
[ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added without its pin"
assert_eq "1.1.19-1" "$(cat "$SANDBOX/solaar-version")" "the Solaar installed without the PPA"
rm "$SANDBOX/solaar-version"
solaar_sources > "$SOLAAR_SOURCES"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$SOLAAR_PIN isn't in place, so the Solaar team's PPA isn't used."
assert_file_not_contains "$STUB_LOG" "install -y solaar"
rm "$SOLAAR_SOURCES"
rmdir "$SOLAAR_PIN"

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installed Solaar 1.1.20."
assert_file_contains "$STUB_LOG" "install -y solaar"
assert_exit 0 main --status

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Solaar 1.1.20 is already installed."
assert_file_not_contains "$STUB_LOG" "sudo"
# Once the PPA is added, neither gpg nor curl is needed
hide gpg curl
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Solaar 1.1.20 is already installed."
stub_gpg_fpr "$SOLAAR_KEY_FPR"
stub_http_status

# Ubuntu's older Solaar is upgraded from the PPA
echo "1.1.19-1" > "$SANDBOX/solaar-version"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Solaar 1.1.20 or later"
assert_exit 0 main
assert_eq "1.1.20+202607061356~ubuntu26.04.1" "$(cat "$SANDBOX/solaar-version")" "the version after upgrading"

# Before the PPA publishes for a new release, Ubuntu's Solaar stands in, and the next run adds it
echo "VERSION_CODENAME=stonking" > "$OS_RELEASE"
stub_http_status 404
rm -f "$SOLAAR_SOURCES" "$SANDBOX/solaar-version"
# Ubuntu's Solaar needs no gpg
hide gpg
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "hasn't published packages for Ubuntu stonking yet"
assert_eq "1.1.19-1" "$(cat "$SANDBOX/solaar-version")" "the version without the PPA"
[ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added before it published for this release"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sudo"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "hasn't published packages for Ubuntu stonking yet"
test_done
