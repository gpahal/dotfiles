#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329

# The chrome step on Ubuntu (amd64), and the Firefox it removes once Chrome is in.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script chrome/install.sh
sandbox_paths chrome/install.sh
as_os ubuntu
stub_sudo_exec
KEY_URL=https://dl.google.com/linux/linux_signing_key.pub

stub_dpkg_arch
# Firefox's snap is there while $SANDBOX/firefox-snap is
stub snap 'case "$*" in
    "list firefox") [ -e "$SANDBOX/firefox-snap" ] ;;
    "remove --purge firefox") rm "$SANDBOX/firefox-snap" ;;
esac'
GOOGLE_SOURCES_CONTENT="${GOOGLE_SOURCES_CONTENT//\/usr\/share\/keyrings\/google-chrome.gpg/$GOOGLE_KEYRING}"
# The key Google serves, with a subkey
stub_gpg_fpr "$GOOGLE_KEY_FPR" 0F06FF86BEEAF4E71866EE5232EE5355A6BC6E42
# Updates fail while $SANDBOX/update-fails exists
stub_apt_packages --apt-get '[[ " $* " != *" update "* ]] || [ ! -e "$SANDBOX/update-fails" ] ||
    { echo "E: The repository is not signed."; exit 100; }'
stub_http_status
stub_fetch key

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Add Google's apt repo, which Chrome updates from, with its pinned key"
assert_contains "$RUN_OUTPUT" "Install google-chrome-stable from Google's apt repo"
assert_contains "$RUN_OUTPUT" "Let unattended-upgrades install Chrome updates: write $UNATTENDED_CONF"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$STUB_LOG" "fetch"
[ ! -e "$UNATTENDED_CONF" ] || fail "the unattended-upgrades file was written without a yes"

# Google builds Chrome for amd64 alone
stub_dpkg_arch arm64
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Chrome: Google has no .deb for arm64"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Google has no Chrome .deb for arm64; skipping."
assert_not_contains "$RUN_OUTPUT" "These need sudo"
stub_dpkg_arch

answer yes

# A failed install leaves Firefox, so the machine keeps a browser
touch "$SANDBOX/fetch-fails" "$SANDBOX/firefox-snap"
assert_exit 1 main
! apt_installed google-chrome-stable || fail "Chrome was installed without Google's key"
[ ! -e "$GOOGLE_SOURCES" ] || fail "Google's apt source was added without its key"
[ -e "$SANDBOX/firefox-snap" ] || fail "Firefox's snap was removed without Chrome"
rm "$SANDBOX/fetch-fails"

# A fresh install adds the repo, keeps Chrome from rewriting it, and removes Firefox's snap
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Applied."
assert_file_contains "$STUB_LOG" "fetch $KEY_URL"
assert_eq "$GOOGLE_SOURCES_CONTENT" "$(cat "$GOOGLE_SOURCES")" "Google's apt source"
assert_eq key "$(cat "$GOOGLE_KEYRING")" "Google's apt key"
assert_eq 'repo_add_once="false"' "$(cat "$CHROME_DEFAULTS")" "Chrome's defaults file"
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y google-chrome-stable"
assert_file_contains "$STUB_LOG" "sudo snap remove --purge firefox"
[ ! -e "$SANDBOX/firefox-snap" ] || fail "Firefox's snap wasn't removed after installing Chrome"
apt_installed google-chrome-stable || fail "Chrome wasn't installed"
assert_eq "$UNATTENDED_CONTENT" "$(cat "$UNATTENDED_CONF")" "the unattended-upgrades file"

before="$(/bin/ls -li "$UNATTENDED_CONF")"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Chrome is already installed and updates automatically."
assert_file_not_contains "$STUB_LOG" "sudo"
assert_file_not_contains "$STUB_LOG" "fetch"
assert_eq "$before" "$(/bin/ls -li "$UNATTENDED_CONF")" "the unattended-upgrades file after a re-run"

# Google's key comes over TLS alone, so the step checks it against the pinned fingerprint
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Google's apt key ($GOOGLE_KEYRING) is the one the step pins"
assert_file_contains "$STUB_LOG" "gpg --show-keys --with-colons $GOOGLE_KEYRING"
stub_gpg_fpr 0123456789ABCDEF0123456789ABCDEF01234567 0F06FF86BEEAF4E71866EE5232EE5355A6BC6E42
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Google's apt key ($GOOGLE_KEYRING) is the one the step pins: $GOOGLE_KEYRING has the fingerprint 0123456789ABCDEF0123456789ABCDEF01234567, not $GOOGLE_KEY_FPR."
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Google's apt key isn't the one the step pins"
hide gpg
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "gpg"
stub_gpg_fpr "$GOOGLE_KEY_FPR"

# Google's apt source removed: the step adds it back, and keeps your other Chrome defaults
rm "$GOOGLE_SOURCES"
printf '%s\n' 'repo_add_once="true"' 'repo_reenable_on_distupgrade="true"' > "$CHROME_DEFAULTS"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Add Google's apt repo"
assert_file_contains "$STUB_LOG" "fetch $KEY_URL"
assert_file_not_contains "$STUB_LOG" "install -y"
assert_eq "$GOOGLE_SOURCES_CONTENT" "$(cat "$GOOGLE_SOURCES")" "Google's apt source after re-adding it"
assert_eq "$(printf '%s\n' 'repo_reenable_on_distupgrade="true"' 'repo_add_once="false"')" "$(cat "$CHROME_DEFAULTS")" \
    "Chrome's defaults file after re-adding the source"

# A disabled source counts as removed
printf 'Types: deb\nURIs: https://dl.google.com/linux/chrome-stable/deb/\nSuites: stable\nComponents: main\nEnabled: no\n' \
    > "$GOOGLE_SOURCES"
assert_exit 1 google_source_exists

# A source apt can't use is put back as it was
disabled="$(cat "$GOOGLE_SOURCES")"
touch "$SANDBOX/update-fails"
assert_exit 1 main
assert_eq "$disabled" "$(cat "$GOOGLE_SOURCES")" "Google's apt source after a failed update"
rm "$SANDBOX/update-fails"
printf '%s\n' "$GOOGLE_SOURCES_CONTENT" > "$GOOGLE_SOURCES"

# Firefox, as Ubuntu installs it: the snap, and the .deb stub that installs it
touch "$SANDBOX/firefox-snap"
echo firefox >> "$SANDBOX/installed"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Firefox removed, since Chrome replaces it"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Remove Firefox, which Chrome replaces: its snap and the firefox .deb that installs it"
assert_file_contains "$STUB_LOG" "sudo snap remove --purge firefox"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 purge -y firefox"
if [ -e "$SANDBOX/firefox-snap" ] || apt_installed firefox; then
    fail "Firefox is still installed"
fi
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Firefox removed, since Chrome replaces it"

# Without Chrome, Firefox stays, so the machine keeps a browser
: > "$SANDBOX/installed"
rm "$GOOGLE_SOURCES"
touch "$SANDBOX/firefox-snap" "$SANDBOX/fetch-fails"
assert_exit 3 main --status
assert_not_contains "$RUN_OUTPUT" "Firefox"
assert_exit 1 main
assert_file_not_contains "$STUB_LOG" "snap remove"
[ -e "$SANDBOX/firefox-snap" ] || fail "Firefox's snap was removed though Chrome's install failed"
rm "$SANDBOX/firefox-snap" "$SANDBOX/fetch-fails"

rm -f "$GOOGLE_SOURCES" "$CHROME_DEFAULTS"
hide curl
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "curl"
[ ! -e "$CHROME_DEFAULTS" ] || fail "Chrome's defaults file was written without curl"
assert_file_not_contains "$STUB_LOG" "sudo"
test_done
