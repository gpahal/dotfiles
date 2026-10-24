#!/bin/bash
# shellcheck disable=SC2329

# The t3-code step's desktop app on Ubuntu: its own server off and its app settings set before it's
# installed, telemetry off through environment.d, and the latest release's .deb checked against
# GitHub's digest.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &> /dev/null || skip "jq isn't installed"
command -v sha256sum &> /dev/null || skip "sha256sum isn't installed"
load_script ai_tools/t3-code/install.sh
as_os ubuntu
replace_fn has_gnome_desktop 'true'
replace_fn running_inside 'false'
SETTINGS="$HOME/.t3/userdata/desktop-settings.json"

printf 'a fake deb' > "$SANDBOX/t3.deb"
release() {
    jq -n --arg digest "$1" '{assets: [
        {name: "T3-Code-0.1.0-arm64.deb", browser_download_url: "https://example.test/arm64.deb", digest: "sha256:0"},
        {name: "T3-Code-0.1.0-amd64.deb", browser_download_url: "https://example.test/amd64.deb", digest: $digest},
        {name: "SHA256SUMS", browser_download_url: "https://example.test/SHA256SUMS"}]}' > "$SANDBOX/release.json"
}
release "sha256:$(sha256sum "$SANDBOX/t3.deb" | cut -d' ' -f1)"

stub_fetch "$T3_CODE_RELEASE_API=$SANDBOX/release.json" "https://example.test/amd64.deb=$SANDBOX/t3.deb"
stub_dpkg_arch
# The app's settings must be in place before it's installed, so its first launch starts no server.
# It comes from a .deb, which installs t3code only when it's the release's.
stub_apt_packages --apt-get '[ -e "$HOME/.t3/userdata/desktop-settings.json" ] || { echo "installed before the settings" >&2; exit 9; }
for arg in "$@"; do case "$arg" in *.deb) cmp -s "$arg" "$SANDBOX/t3.deb" && echo t3code >> "$SANDBOX/installed"; exit 0 ;; esac; done'
stub pgrep 'exit 1'
# status also reports the service, which test-t3-service.sh covers
stub ss 'exit 1'
stub_sudo_exec

assert_exit 3 main --status
cp "$STUB_LOG" "$SANDBOX/both.log"

answer no
assert_exit 0 setup_t3_code_desktop_ubuntu
cat "$STUB_LOG" >> "$SANDBOX/both.log"
assert_file_not_contains "$SANDBOX/both.log" "apt-get"
assert_eq "false" "$(jq -r .localEnvironmentEnabled "$SETTINGS")" "the desktop app's own server, before the install"
assert_eq "steer" "$(jq -r .followUpBehavior "$HOME/.t3/userdata/client-settings.json")" "the desktop app's follow-up behavior"

answer yes
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_file_contains "$STUB_LOG" "install -y"
grep -qx t3code "$SANDBOX/installed" || fail "the .deb wasn't installed"
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code desktop app"
assert_contains "$RUN_OUTPUT" "ok         Desktop app's own server off"

# Installed: it updates itself, so nothing is fetched again
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_file_not_contains "$STUB_LOG" "curl"

# A running app keeps its settings until it's quit
jq_edit "$SETTINGS" '.localEnvironmentEnabled = true'
stub pgrep '[ "${*: -1}" == t3code ]'
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_eq "true" "$(jq -r .localEnvironmentEnabled "$SETTINGS")" "settings while the app runs"
stub pgrep 'exit 1'

# A .deb that doesn't match GitHub's digest, or no .deb for this architecture, installs nothing
: > "$SANDBOX/installed"
release "sha256:0000"
assert_exit 1 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "doesn't match the digest"
! grep -qx t3code "$SANDBOX/installed" || fail "a .deb that didn't match its digest was installed"
stub_dpkg_arch riscv64
assert_exit 1 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "no riscv64 .deb"

# Ubuntu Server has no desktop to run it
replace_fn has_gnome_desktop 'false'
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_eq "" "$(cat "$STUB_LOG")" "commands run without a desktop"

test_done
