#!/bin/bash
set -euo pipefail

# The homebrew step's main; test-homebrew-install.sh covers installing Homebrew itself.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script homebrew/install.sh
# No app path for an unlisted cask, so nothing reads the real Mac's apps
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=()
replace_fn cask_app_path
FONTS="$HOME/.local/share/fonts"

stub brew 'S="'"$SANDBOX"'"
app_json() { printf "{\"token\": \"%s\", \"artifacts\": [{\"app\": [\"x.app\"], \"target\": \"%s\"}]}" "$1" "$S/apps/$1.app"; }
case "$1 $2" in
    "bundle check")
        [ -e "$S/bundle-ok" ] ;;
    "bundle install")
        st="$(cat "$S/bundle-status" 2>/dev/null || echo 0)"
        [ "$st" -ne 0 ] || touch "$S/bundle-ok"
        exit "$st"
        ;;
    "list --cask") if [ "$3" == -1 ]; then cat "$S/casks"; else grep -qxF "$3" "$S/casks"; fi ;;
    "info --json=v2")
        if [ "$3" == --installed ]; then
            sep=""; printf "{\"casks\": ["
            while read -r c; do printf "%s" "$sep"; app_json "$c"; sep=,; done < "$S/casks"
            echo "]}"
        else
            printf "{\"casks\": ["; app_json "$4"; echo "]}"
        fi
        ;;
    "install --cask" | "reinstall --cask")
        st="$(grep "^$3=" "$S/cask-status" | cut -d= -f2)"
        [ -z "$st" ] || exit "$st"
        [ "$1" == reinstall ] || echo "$3" >> "$S/casks"
        mkdir -p "$S/apps/$3.app"
        fonts="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
        [ "$3" != font-monaspace ] || { mkdir -p "$fonts"; touch "$fonts/Monaspace.otf"; }
        ;;
esac'
stub mas 'S="'"$SANDBOX"'"
case "$1" in
    list) while read -r id; do printf " %s  App  (1.0)\n" "$id"; done < "$S/mas-installed" ;;
    install | get)
        [ ! -f "$S/mas-status" ] || exit "$(cat "$S/mas-status")"
        list="$S/mas-owned"
        [ "$1" == install ] || list="$S/mas-free"
        grep -qxF "$2" "$list" || exit 1
        echo "$2" >> "$S/mas-installed"
        ;;
esac'
AMPHETAMINE=937984704 DATO=1470584107 WINDOWS_APP=1295203466
stub xcode-select
stub fc-cache
stub sudo 'exit 0'
reset() {
    rm -rf "$SANDBOX/bundle-ok" "$SANDBOX/bundle-status" "$SANDBOX/apps" "$FONTS" "$SANDBOX/mas-status"
    : > "$SANDBOX/casks"
    : > "$SANDBOX/cask-status"
    printf '%s\n' "$AMPHETAMINE" "$DATO" "$WINDOWS_APP" > "$SANDBOX/mas-installed"
    : > "$SANDBOX/mas-owned"
    : > "$SANDBOX/mas-free"
    : > "$STUB_LOG"
}
installs() {
    grep -E '^(brew (bundle install|install|reinstall)|mas (install|get))' "$STUB_LOG" | sed 's/ --file=[^ ]*//' || true
}

as_os macos
# Setup refuses Intel, so fake arm64 even on an x86_64 runner
stub uname 'if [ "$1" == -m ]; then echo arm64; else exec /usr/bin/uname "$@"; fi'

reset
stub xcode-select '[ "$1" != -p ] || exit 2'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Finish the Command Line Tools install"
assert_file_contains "$STUB_LOG" "xcode-select --install"
assert_eq "" "$(installs)" "brew installs without the Command Line Tools"
stub xcode-select

# Not signed in to the App Store: warn with the sign-in steps, note the optional Dato, and pass
reset
touch "$SANDBOX/bundle-ok"
: > "$SANDBOX/mas-installed"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Couldn't install from the App Store: Amphetamine, Windows App."
assert_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_contains "$RUN_OUTPUT" "sudo -v"
assert_contains "$RUN_OUTPUT" "Not installed, and optional: Dato."
assert_eq "mas install $AMPHETAMINE
mas get $AMPHETAMINE
mas install $DATO
mas install $WINDOWS_APP
mas get $WINDOWS_APP
$(printf 'brew install --cask %s\n' "${CASKS[@]}")" "$(installs)" "installs on a new Mac"

# Signed in: mas get for a free app the account lacks, mas install for an owned one
reset
touch "$SANDBOX/bundle-ok"
: > "$SANDBOX/mas-installed"
printf '%s\n' "$AMPHETAMINE" "$DATO" > "$SANDBOX/mas-owned"
echo "$WINDOWS_APP" > "$SANDBOX/mas-free"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_not_contains "$RUN_OUTPUT" "optional"
assert_eq "mas install $AMPHETAMINE
mas install $DATO
mas install $WINDOWS_APP
mas get $WINDOWS_APP" "$(installs | grep '^mas')" "App Store installs when signed in"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "App Store apps already installed."
assert_eq "" "$(installs)" "installs on a re-run"
assert_eq 1 "$(grep -c '^mas list' "$STUB_LOG")" "mas list calls on a re-run"
grep -vxF "$DATO" "$SANDBOX/mas-installed" > "$SANDBOX/mas-left" && mv "$SANDBOX/mas-left" "$SANDBOX/mas-installed"
: > "$SANDBOX/mas-owned"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Not installed, and optional: Dato."
assert_not_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_eq "mas install $DATO" "$(installs)" "installs with Dato not bought"

# A failed bundle: the rest is still tried, and the step fails with its status
reset
echo 1 > "$SANDBOX/bundle-status"
: > "$SANDBOX/mas-installed"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_eq "brew bundle install --no-upgrade
mas install $AMPHETAMINE
mas get $AMPHETAMINE
mas install $DATO
mas install $WINDOWS_APP
mas get $WINDOWS_APP
$(printf 'brew install --cask %s\n' "${CASKS[@]}")" "$(installs)" "installs after a failed bundle"

reset
echo 1 > "$SANDBOX/bundle-status"
: > "$SANDBOX/mas-installed"
subtest eval 'hide mas; assert_exit 1 main; assert_contains "$RUN_OUTPUT" "mas isn'"'"'t installed"'

reset
touch "$SANDBOX/bundle-ok"
: > "$SANDBOX/mas-installed"
echo 130 > "$SANDBOX/mas-status"
assert_exit 130 main
assert_eq "mas install $AMPHETAMINE" "$(installs)" "installs before Ctrl-C in mas"

reset
touch "$SANDBOX/bundle-ok"
echo "zed=1" > "$SANDBOX/cask-status"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "These casks failed to install: zed."
assert_eq "${#CASKS[@]}" "$(installs | grep -c 'install --cask')" "casks tried"
assert_eq "$((${#CASKS[@]} - 1))" "$(wc -l < "$SANDBOX/casks" | tr -d ' ')" "casks installed"

: > "$SANDBOX/cask-status"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "brew install --cask zed" "$(installs)" "installs on a re-run"
assert_contains "$RUN_OUTPUT" "Brew formulae already installed."

rm -rf "$SANDBOX/apps/raycast.app"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "brew reinstall --cask raycast" "$(installs)" "installs with raycast's app deleted"
assert_contains "$RUN_OUTPUT" "brew lists raycast, but its app is gone; reinstalling it..."
[ -d "$SANDBOX/apps/raycast.app" ] || fail "raycast's app wasn't reinstalled"

reset
touch "$SANDBOX/bundle-ok"
echo "zed=130" > "$SANDBOX/cask-status"
assert_exit 130 main
assert_eq "$(printf 'brew install --cask %s\n' font-monaspace ghostty zed)" "$(installs)" "installs before Ctrl-C"

reset
echo 130 > "$SANDBOX/bundle-status"
assert_exit 130 main
assert_eq "brew bundle install --no-upgrade" "$(installs)" "installs after Ctrl-C in the bundle"

as_os ubuntu
replace_fn locale_installed 'return 0'

reset
replace_fn missing_ubuntu_commands 'echo " jq"'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Missing commands: jq"
assert_contains "$RUN_OUTPUT" "Install them with: sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $UBUNTU_PACKAGES"
assert_file_not_contains "$STUB_LOG" "sudo"
assert_eq "" "$(installs)" "brew installs without the apt packages"

# apt-get update is retried only for apt's lists lock, which apt-daily can hold
stub_sudo_exec
stub apt-get 'S="'"$SANDBOX"'"
[ "${*: -1}" == update ] || exit 0
if [ -e "$S/apt-broken" ]; then
    echo "E: The repository http://example.invalid resolute Release does not have a Release file." >&2
    exit 100
fi
n="$(cat "$S/locked" 2>/dev/null || echo 0)"
[ "$n" -gt 0 ] || exit 0
echo $((n - 1)) > "$S/locked"
echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 812 (apt-get)" >&2
echo "E: Unable to lock directory /var/lib/apt/lists/" >&2
exit 100'
# Fewer tries than the step's, but enough for two lock failures then a success
# shellcheck disable=SC2034 # apt_get_update reads them
APT_UPDATE_RETRY_DELAY=0 APT_UPDATE_TRIES=4
updates() { grep -c "^apt-get .* update$" "$STUB_LOG" || true; }
replace_fn missing_ubuntu_commands 'echo " jq"'
reset
echo 2 > "$SANDBOX/locked"
answer yes
assert_exit 0 main
assert_eq 3 "$(updates)" "apt-get updates after two lock failures"
assert_contains "$RUN_OUTPUT" "apt's lists lock is held"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y $UBUNTU_PACKAGES"
reset
echo 100 > "$SANDBOX/locked"
assert_exit 1 main
assert_eq "$APT_UPDATE_TRIES" "$(updates)" "apt-get updates while the lock stays held"
assert_file_not_contains "$STUB_LOG" "install -y $UBUNTU_PACKAGES"
reset
rm -f "$SANDBOX/locked"
touch "$SANDBOX/apt-broken"
assert_exit 1 main
assert_eq 1 "$(updates)" "apt-get updates after another error"
assert_contains "$RUN_OUTPUT" "does not have a Release file"
rm "$SANDBOX/apt-broken"
stub sudo 'exit 0'
answer no

reset
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update"
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y $UBUNTU_PACKAGES"
assert_contains "$RUN_OUTPUT" "Installing brew formulae..." "Ubuntu output"
assert_eq "$(printf 'brew bundle install --no-upgrade\n'; printf 'brew install --cask %s\n' "${UBUNTU_CASKS[@]}")" "$(installs)" "installs on Ubuntu"
assert_file_contains "$STUB_LOG" "fc-cache -f $FONTS"

answer no

replace_fn missing_ubuntu_commands
: > "$STUB_LOG"
touch "$SANDBOX/bundle-ok"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "apt packages already installed."
assert_contains "$RUN_OUTPUT" "Brew casks already installed."
assert_file_not_contains "$STUB_LOG" "fc-cache"
assert_file_not_contains "$STUB_LOG" "sudo"

reset
export XDG_DATA_HOME="$SANDBOX/data"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "fc-cache -f $XDG_DATA_HOME/fonts"
unset XDG_DATA_HOME

# Installer casks have no app artifact, so CASK_PKG_APPS names their apps
as_os macos
CASKS=(tailscale-app logi-options+)
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=("tailscale-app=$SANDBOX/apps/tailscale-app.app" "logi-options+=$SANDBOX/apps/logi-options+.app")
stub brew 'S="'"$SANDBOX"'"
case "$1 $2" in
    "list --cask") exit 0 ;;
    "info --json=v2") echo '\''{"casks":[{"token":"tailscale-app","artifacts":[{"pkg":["t.pkg"]}]},{"token":"logi-options+","artifacts":[{"pkg":["l.pkg"]}]}]}'\'' ;;
    "reinstall --cask") mkdir -p "$S/apps/$3.app" ;;
esac'
rm -rf "$SANDBOX/apps"
: > "$STUB_LOG"
assert_exit 0 install_casks
assert_file_contains "$STUB_LOG" 'brew reinstall --cask tailscale-app'
assert_file_contains "$STUB_LOG" 'brew reinstall --cask logi-options+'
: > "$STUB_LOG"
assert_exit 0 install_casks
assert_file_not_contains "$STUB_LOG" 'reinstall'
rm -rf "$SANDBOX/apps/tailscale-app.app"
assert_eq "gone	$SANDBOX/apps/tailscale-app.app" "$(cask_state tailscale-app "" $'tailscale-app\t')" \
    "the state of an installer cask whose app was deleted"

# An app installed outside Homebrew counts as installed
CASKS=(outside)
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=("outside=$SANDBOX/apps/outside.app")
mkdir -p "$SANDBOX/apps/outside.app"
stub brew '[ "$1 $2" != "info --json=v2" ] || echo '\''{"casks": []}'\''; [ "$1 $2" != "list --cask" ]'
: > "$STUB_LOG"
assert_exit 0 install_casks
assert_contains "$RUN_OUTPUT" "Brew casks already installed."
assert_not_contains "$RUN_OUTPUT" "Installing brew casks"
assert_file_not_contains "$STUB_LOG" "outside"
test_done
