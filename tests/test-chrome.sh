#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The chrome step on Ubuntu (amd64), and the Firefox it removes once Chrome is in.

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
# Firefox's snap and its .deb are there while $SANDBOX/firefox-snap and firefox-deb are
stub dpkg-query 'case "${!#}" in
    google-chrome-stable) [ ! -e "'"$SANDBOX"'/installed" ] || echo "install ok installed" ;;
    firefox) [ ! -e "'"$SANDBOX"'/firefox-deb" ] || echo "install ok installed" ;;
esac'
stub snap 'case "$*" in
    "list firefox") [ -e "'"$SANDBOX"'/firefox-snap" ] ;;
    "remove --purge firefox") rm "'"$SANDBOX"'/firefox-snap" ;;
esac'
CHROME_DEFAULTS="$SANDBOX/default-google-chrome"
GOOGLE_KEYRING="$SANDBOX/google-chrome.gpg"
# The key the .deb installed has the fingerprint in $SANDBOX/google-key
echo "$GOOGLE_KEY_FPR" > "$SANDBOX/google-key"
stub gpg 'printf "pub:-\nfpr:::::::::%s:\nsub:-\nfpr:::::::::0F06FF86BEEAF4E71866EE5232EE5355A6BC6E42:\n" "$(cat "'"$SANDBOX"'/google-key")"'
# Fails unless the .deb is world-readable. Like Google's .deb, adds its apt source on first
# install, later only when repo_add_once="true".
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
stub curl 'cat "'"$SANDBOX"'/http-status"'
echo 200 > "$SANDBOX/http-status"
replace_fn fetch 'echo "fetch $1" >> "$STUB_LOG"
[ ! -e "$SANDBOX/fetch-fails" ] || return 1
echo deb > "$2"'

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install google-chrome-stable from Google's .deb"
assert_contains "$RUN_OUTPUT" "Let unattended-upgrades install Chrome updates: write $UNATTENDED_CONF"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$STUB_LOG" "fetch"
[ ! -e "$UNATTENDED_CONF" ] || fail "the unattended-upgrades file was written without a yes"

echo 000 > "$SANDBOX/http-status"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't reach dl.google.com"
assert_not_contains "$RUN_OUTPUT" "These need sudo"
echo 200 > "$SANDBOX/http-status"

export DOTFILES_ASSUME_YES=1

touch "$SANDBOX/fetch-fails"
assert_exit 1 main
[ ! -e "$SANDBOX/installed" ] || fail "Chrome was installed without its .deb"
rm "$SANDBOX/fetch-fails"

# A fresh install removes Firefox's snap once Chrome is in
touch "$SANDBOX/firefox-snap"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Applied."
assert_file_contains "$STUB_LOG" "fetch $URL"
assert_file_contains "$STUB_LOG" "sudo snap remove --purge firefox"
[ ! -e "$SANDBOX/firefox-snap" ] || fail "Firefox's snap wasn't removed after installing Chrome"
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y"
[ -e "$SANDBOX/installed" ] || fail "Chrome wasn't installed"
deb="$(cat "$SANDBOX/deb-path")"
assert_eq google-chrome-stable.deb "${deb##*/}" "the .deb apt-get installed"
[ ! -e "$(dirname "$deb")" ] || fail "the .deb's temp dir is still there"
assert_eq "$UNATTENDED_CONTENT" "$(cat "$UNATTENDED_CONF")" "the unattended-upgrades file"

before="$(/bin/ls -li "$UNATTENDED_CONF")"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Chrome is already installed and updates automatically."
assert_file_not_contains "$STUB_LOG" "sudo"
assert_file_not_contains "$STUB_LOG" "curl"
assert_eq "$before" "$(/bin/ls -li "$UNATTENDED_CONF")" "the unattended-upgrades file after a re-run"

# Google's key comes over TLS alone, so the step checks it against the pinned fingerprint
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Google's apt key ($GOOGLE_KEYRING) is the one the step pins"
assert_file_contains "$STUB_LOG" "gpg --show-keys --with-colons $GOOGLE_KEYRING"
echo 0123456789ABCDEF0123456789ABCDEF01234567 > "$SANDBOX/google-key"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Google's apt key ($GOOGLE_KEYRING) is the one the step pins: $GOOGLE_KEYRING has the fingerprint 0123456789ABCDEF0123456789ABCDEF01234567, not $GOOGLE_KEY_FPR."
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Google's apt key isn't the one the step pins"
echo "$GOOGLE_KEY_FPR" > "$SANDBOX/google-key"
hide gpg
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "gpg"
stub gpg 'printf "pub:-\nfpr:::::::::%s:\n" "$(cat "'"$SANDBOX"'/google-key")"'

echo "// edited" > "$UNATTENDED_CONF"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "$UNATTENDED_CONTENT" "$(cat "$UNATTENDED_CONF")" "the unattended-upgrades file after an edit"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_file_not_contains "$STUB_LOG" "fetch"

# Google's apt source removed: reinstalling with repo_add_once re-adds it
rm "$GOOGLE_SOURCES"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Re-add Google's apt repo"
assert_file_contains "$STUB_LOG" "fetch $URL"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y --reinstall"
[ -e "$GOOGLE_SOURCES" ] || fail "Google's apt source wasn't re-added"
assert_file_contains "$CHROME_DEFAULTS" 'repo_reenable_on_distupgrade="true"'
assert_eq 1 "$(grep -c '^repo_add_once=' "$CHROME_DEFAULTS")" "repo_add_once lines"

stub apt-get
rm "$GOOGLE_SOURCES"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Add it by hand"
touch "$GOOGLE_SOURCES"

# Firefox, as Ubuntu installs it: the snap, and the .deb stub that installs it
stub apt-get '[ "$*" != "-o DPkg::Lock::Timeout=300 purge -y firefox" ] || rm "'"$SANDBOX"'/firefox-deb"'
touch "$SANDBOX/firefox-snap" "$SANDBOX/firefox-deb"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Firefox removed, since Chrome replaces it"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Remove Firefox, which Chrome replaces: its snap and the firefox .deb that installs it"
assert_file_contains "$STUB_LOG" "sudo snap remove --purge firefox"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 purge -y firefox"
[ ! -e "$SANDBOX/firefox-snap" ] && [ ! -e "$SANDBOX/firefox-deb" ] || fail "Firefox is still installed"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Firefox removed, since Chrome replaces it"

# The .deb stub can bring the snap back; only the snap is removed then
touch "$SANDBOX/firefox-snap"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo snap remove --purge firefox"
assert_file_not_contains "$STUB_LOG" "purge -y firefox"

# Without Chrome, Firefox stays, so the machine keeps a browser
rm "$SANDBOX/installed"
touch "$SANDBOX/firefox-snap"
answer no
assert_exit 3 main --status
assert_not_contains "$RUN_OUTPUT" "Firefox"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$STUB_LOG" "snap remove"
answer yes
touch "$SANDBOX/installed"
rm "$SANDBOX/firefox-snap"

rm -f "$GOOGLE_SOURCES" "$CHROME_DEFAULTS"
hide curl
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "curl"
[ ! -e "$CHROME_DEFAULTS" ] || fail "Chrome's defaults file was written without curl"
assert_file_not_contains "$STUB_LOG" "sudo"

as_os macos
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "chrome: skipped, Ubuntu only" "$RUN_OUTPUT" "the step on macOS"
assert_exit 0 main --status
assert_eq "  skipped    Ubuntu only" "$RUN_OUTPUT" "the step's status on macOS"
assert_eq "" "$(cat "$STUB_LOG")" "commands the skipped step ran"
test_done
