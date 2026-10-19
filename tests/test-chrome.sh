#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The chrome step on Ubuntu (amd64): it installs Chrome from Google's .deb, readable by apt's
# sandbox user, removes the download, and writes the unattended-upgrades file once. A missing
# Google apt source is re-added by setting repo_add_once in /etc/default/google-chrome and
# reinstalling the .deb. A failed download fails the step, as does dl.google.com being
# unreachable. It leaves enabling daily unattended upgrades to the ubuntu step.
# test-unattended-upgrades.sh covers the step's status.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script chrome/install.sh
as_os ubuntu
stub_sudo_exec
UNATTENDED_CONF="$SANDBOX/52dotfiles-google-chrome"
GOOGLE_SOURCES="$SANDBOX/google-chrome.sources"
URL=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

stub dpkg '[ "$1" != --print-architecture ] || echo amd64'
# Chrome is installed once apt-get has installed the .deb
stub dpkg-query '[ ! -e "'"$SANDBOX"'/installed" ] || echo "install ok installed"'
CHROME_DEFAULTS="$SANDBOX/default-google-chrome"
# apt-get records the .deb's path and whether its directory and the file are world-readable. As
# Google's .deb does, it adds Google's apt source on the first install, and later only when
# $CHROME_DEFAULTS sets repo_add_once="true", which it then sets back to false.
stub apt-get 'deb="${!#}"
echo "$deb" > "'"$SANDBOX"'/deb-path"
[ -r "$deb" ] && [ "$(cut -c8 <<< "$(/bin/ls -ld "$(dirname "$deb")")")" == r ] &&
    [ "$(cut -c8 <<< "$(/bin/ls -l "$deb")")" == r ] || { echo "the .deb isn'"'"'t world-readable" >&2; exit 1; }
defaults="'"$CHROME_DEFAULTS"'"
if [ ! -e "'"$SANDBOX"'/installed" ] || grep -qx "repo_add_once=\"true\"" "$defaults" 2>/dev/null; then
    printf "Types: deb\nURIs: https://dl.google.com/linux/chrome-stable/deb/\nSuites: stable\nComponents: main\n" > "'"$GOOGLE_SOURCES"'"
fi
if [ -e "$defaults" ]; then
    { grep -v "^repo_add_once=" "$defaults" || true; echo "repo_add_once=\"false\""; } > "$defaults.new"
    mv "$defaults.new" "$defaults"
else
    printf "repo_add_once=\"false\"\nrepo_reenable_on_distupgrade=\"true\"\n" > "$defaults"
fi
touch "'"$SANDBOX"'/installed"'
# curl answers the HEAD request with $SANDBOX/http-status
stub curl 'cat "'"$SANDBOX"'/http-status"'
echo 200 > "$SANDBOX/http-status"
replace_fn fetch 'echo "fetch $1" >> "$STUB_LOG"
[ ! -e "$SANDBOX/fetch-fails" ] || return 1
echo deb > "$2"'

# Declined: nothing downloaded or written
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install google-chrome-stable from Google's .deb"
assert_contains "$RUN_OUTPUT" "Let unattended-upgrades install Chrome updates: write $UNATTENDED_CONF"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$STUB_LOG" "fetch"
[ ! -e "$UNATTENDED_CONF" ] || fail "the unattended-upgrades file was written without a yes"

# dl.google.com can't be reached: the step fails before asking
echo 000 > "$SANDBOX/http-status"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't reach dl.google.com"
assert_not_contains "$RUN_OUTPUT" "These need sudo"
echo 200 > "$SANDBOX/http-status"

export DOTFILES_ASSUME_YES=1

# The download fails: the step fails, and installs nothing
touch "$SANDBOX/fetch-fails"
assert_exit 1 main
[ ! -e "$SANDBOX/installed" ] || fail "Chrome was installed without its .deb"
rm "$SANDBOX/fetch-fails"

# Approved: the .deb installs, then goes, and the unattended-upgrades file is written
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Applied."
assert_file_contains "$STUB_LOG" "fetch $URL"
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y"
[ -e "$SANDBOX/installed" ] || fail "Chrome wasn't installed"
deb="$(cat "$SANDBOX/deb-path")"
assert_eq google-chrome-stable.deb "${deb##*/}" "the .deb apt-get installed"
[ ! -e "$(dirname "$deb")" ] || fail "the .deb's temp dir is still there"
assert_eq "$UNATTENDED_CONTENT" "$(cat "$UNATTENDED_CONF")" "the unattended-upgrades file"

# Re-run: nothing to do, the file is left as is, and nothing runs with sudo
before="$(/bin/ls -li "$UNATTENDED_CONF")"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Chrome is already installed and updates automatically."
assert_file_not_contains "$STUB_LOG" "sudo"
assert_file_not_contains "$STUB_LOG" "curl"
assert_eq "$before" "$(/bin/ls -li "$UNATTENDED_CONF")" "the unattended-upgrades file after a re-run"

# A changed file is rewritten, without reinstalling Chrome
echo "// edited" > "$UNATTENDED_CONF"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "$UNATTENDED_CONTENT" "$(cat "$UNATTENDED_CONF")" "the unattended-upgrades file after an edit"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_file_not_contains "$STUB_LOG" "fetch"

# Google's apt source was removed: a yes sets repo_add_once in Chrome's defaults file, keeping its
# other settings, and reinstalls the .deb, which adds the source back
rm "$GOOGLE_SOURCES"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Re-add Google's apt repo"
assert_file_contains "$STUB_LOG" "fetch $URL"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y --reinstall"
[ -e "$GOOGLE_SOURCES" ] || fail "Google's apt source wasn't re-added"
assert_file_contains "$CHROME_DEFAULTS" 'repo_reenable_on_distupgrade="true"'
assert_eq 1 "$(grep -c '^repo_add_once=' "$CHROME_DEFAULTS")" "repo_add_once lines"

# The .deb doesn't add it: the step fails, saying to add it by hand
stub apt-get
rm "$GOOGLE_SOURCES"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Add it by hand"
touch "$GOOGLE_SOURCES"

# Without curl, re-adding Google's apt source, which downloads the .deb, fails before it writes
# Chrome's defaults file
rm -f "$GOOGLE_SOURCES" "$CHROME_DEFAULTS"
hide curl
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "curl"
[ ! -e "$CHROME_DEFAULTS" ] || fail "Chrome's defaults file was written without curl"
assert_file_not_contains "$STUB_LOG" "sudo"

# On macOS, STEP_OS=ubuntu skips the step, run or reported, without running any of it
as_os macos
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "chrome: skipped, Ubuntu only" "$RUN_OUTPUT" "the step on macOS"
assert_exit 0 main --status
assert_eq "  skipped    Ubuntu only" "$RUN_OUTPUT" "the step's status on macOS"
assert_eq "" "$(cat "$STUB_LOG")" "commands the skipped step ran"
test_done
