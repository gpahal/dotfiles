#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# The t3-code step's desktop app on Ubuntu: its own server off and its app settings set before it's
# installed, telemetry off through environment.d, and the latest release's .deb checked against
# GitHub's digest.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"
command -v sha256sum &> /dev/null || skip "sha256sum isn't installed"
load_script ai_tools/t3-code/install.sh
as_os ubuntu
replace_fn has_gnome_desktop 'true'
replace_fn running_inside 'false'
export SANDBOX
SETTINGS="$HOME/.t3/userdata/desktop-settings.json"

printf 'a fake deb' > "$SANDBOX/t3.deb"
release() {
    jq -n --arg digest "$1" '{assets: [
        {name: "T3-Code-0.1.0-arm64.deb", browser_download_url: "https://example.test/arm64.deb", digest: "sha256:0"},
        {name: "T3-Code-0.1.0-amd64.deb", browser_download_url: "https://example.test/amd64.deb", digest: $digest},
        {name: "SHA256SUMS", browser_download_url: "https://example.test/SHA256SUMS"}]}' > "$SANDBOX/release.json"
}
release "sha256:$(sha256sum "$SANDBOX/t3.deb" | cut -d' ' -f1)"

# fetch's curl: the last argument is the URL, and -o names the file
stub curl 'out=""; prev=""
for arg in "$@"; do [ "$prev" != -o ] || out="$arg"; prev="$arg"; done
case "${*: -1}" in
    */releases/latest) cp "$SANDBOX/release.json" "$out" ;;
    */amd64.deb) cp "$SANDBOX/t3.deb" "$out" ;;
    *) exit 22 ;;
esac'
stub dpkg '[ "$1" == --print-architecture ] && echo amd64'
stub dpkg-query '[ "${*: -1}" == t3code ] && [ -e "$SANDBOX/installed" ] && printf "install ok installed"'
# The app's settings must be in place before it's installed, so its first launch starts no server
stub apt-get '[ -e "$HOME/.t3/userdata/desktop-settings.json" ] || { echo "installed before the settings" >&2; exit 9; }
for arg in "$@"; do case "$arg" in *.deb) cmp -s "$arg" "$SANDBOX/t3.deb" && touch "$SANDBOX/installed" ;; esac; done'
stub pgrep 'exit 1'
# status also reports the service, which test-t3-service.sh covers
stub ss 'exit 1'
stub_sudo_exec

assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    T3 Code desktop app"
assert_contains "$RUN_OUTPUT" "missing    ~/.config/environment.d/60-dotfiles-t3code.conf"
assert_contains "$RUN_OUTPUT" "missing    Desktop app's own server off in ~/.t3/userdata/desktop-settings.json"
assert_contains "$RUN_OUTPUT" "missing    App settings in ~/.t3/userdata/client-settings.json"

answer no
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_eq "false" "$(jq -r .localEnvironmentEnabled "$SETTINGS")" "the desktop app's own server, before the install"
assert_eq "steer" "$(jq -r .followUpBehavior "$HOME/.t3/userdata/client-settings.json")" "the desktop app's follow-up behavior"

answer yes
: > "$STUB_LOG"
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "The desktop app's own server is already off, and its app settings are set"
assert_file_contains "$STUB_LOG" "curl -fsSL --proto =https --tlsv1.2 --connect-timeout 15 --speed-limit 1 --speed-time 60 --retry 3 --retry-delay 2 -o"
assert_file_contains "$STUB_LOG" "install -y"
[ -e "$SANDBOX/installed" ] || fail "the .deb wasn't installed"
assert_eq "$(cat "$REPO_DIR/ai_tools/t3-code/60-dotfiles-t3code.conf")" \
    "$(cat "$HOME/.config/environment.d/60-dotfiles-t3code.conf")" "the telemetry setting"
assert_file_contains "$HOME/.config/environment.d/60-dotfiles-t3code.conf" "T3CODE_TELEMETRY_ENABLED=false"
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code desktop app"
assert_contains "$RUN_OUTPUT" "ok         ~/.config/environment.d/60-dotfiles-t3code.conf"
assert_contains "$RUN_OUTPUT" "ok         Desktop app's own server off"
assert_contains "$RUN_OUTPUT" "ok         App settings in ~/.t3/userdata/client-settings.json"

# Installed: it updates itself, so nothing is fetched again
: > "$STUB_LOG"
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "The T3 Code desktop app is already installed; it updates itself."
assert_file_not_contains "$STUB_LOG" "curl"

# A running app keeps its settings until it's quit
jq '.localEnvironmentEnabled = true' "$SETTINGS" > "$SANDBOX/s.json" && cp "$SANDBOX/s.json" "$SETTINGS"
stub pgrep '[ "${*: -1}" == t3code ]'
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "t3code is running and must be quit to change its settings"
assert_eq "true" "$(jq -r .localEnvironmentEnabled "$SETTINGS")" "settings while the app runs"
stub pgrep 'exit 1'

# A .deb that doesn't match GitHub's digest, or no .deb for this architecture, installs nothing
rm "$SANDBOX/installed"
release "sha256:0000"
assert_exit 1 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "T3 Code's .deb doesn't match the digest GitHub lists for it, so it wasn't installed."
[ ! -e "$SANDBOX/installed" ] || fail "a .deb that didn't match its digest was installed"
stub dpkg '[ "$1" == --print-architecture ] && echo riscv64'
assert_exit 1 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "T3 Code's latest release has no riscv64 .deb with a digest, so nothing was installed."

# Ubuntu Server has no desktop to run it
replace_fn has_gnome_desktop 'false'
: > "$STUB_LOG"
assert_exit 0 setup_t3_code_desktop_ubuntu
assert_contains "$RUN_OUTPUT" "No GNOME desktop, so no desktop app; the service runs the server."
assert_eq "" "$(cat "$STUB_LOG")" "commands run without a desktop"

test_done
