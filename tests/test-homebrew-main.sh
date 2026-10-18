#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The homebrew step's main: the Command Line Tools on macOS and the apt packages on Ubuntu come
# first, a failed bundle still installs the App Store apps and casks, one failed cask doesn't stop
# the rest, an app installed outside Homebrew counts as installed, Ctrl-C (exit 130 from brew or
# mas) stops the step, the App Store apps install with mas install, then mas get, and only warn
# when they fail, with the optional Dato only a note and never installed,
# apt-get update is retried only while another update holds apt's lists lock, Ubuntu refreshes the
# font cache after a cask install, and a re-run installs nothing. test-homebrew-install.sh covers
# installing Homebrew itself.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script homebrew/install.sh
# No app path for a cask brew doesn't list, so nothing asks brew info or finds the real Mac's apps
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=()
cask_app_path() { :; }
FONTS="$HOME/.local/share/fonts"

# brew: the bundle is installed when $SANDBOX/bundle-ok exists. bundle install exits with
# $SANDBOX/bundle-status, creating bundle-ok when that's 0. The casks in $SANDBOX/casks are
# installed, each with its app at $SANDBOX/apps/<cask>.app. Installing one exits with the status
# after its name in $SANDBOX/cask-status, creates its app, and for font-monaspace adds a font where
# Homebrew would.
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
# mas: the ids in $SANDBOX/mas-installed are installed. mas install installs an id in
# $SANDBOX/mas-owned, and mas get one in $SANDBOX/mas-free; either exits with $SANDBOX/mas-status
# when it's there.
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
# reset: nothing installed but the App Store apps other than the optional Dato
reset() {
    rm -rf "$SANDBOX/bundle-ok" "$SANDBOX/bundle-status" "$SANDBOX/apps" "$FONTS" "$SANDBOX/mas-status"
    : > "$SANDBOX/casks"
    : > "$SANDBOX/cask-status"
    printf '%s\n' "$AMPHETAMINE" "$WINDOWS_APP" > "$SANDBOX/mas-installed"
    : > "$SANDBOX/mas-owned"
    : > "$SANDBOX/mas-free"
    : > "$STUB_LOG"
}
installs() {
    grep -E '^(brew (bundle install|install|reinstall)|mas (install|get))' "$STUB_LOG" | sed 's/ --file=[^ ]*//' || true
}

is_macos() { true; }
is_ubuntu() { false; }
# An Apple Silicon Mac, even on an x86_64 CI runner: setup refuses Intel
stub uname 'if [ "$1" == -m ]; then echo arm64; else exec /usr/bin/uname "$@"; fi'

# No Command Line Tools: their installer opens, and the step stops
reset
stub xcode-select '[ "$1" != -p ] || exit 2'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Finish the Command Line Tools install"
assert_file_contains "$STUB_LOG" "xcode-select --install"
assert_eq "" "$(installs)" "brew installs without the Command Line Tools"
stub xcode-select

# A new Mac, not signed in to the App Store: mas install, then mas get, fail for each App Store app
# but the optional Dato. The step warns with the sign-in steps, naming sudo, which mas 7 installs
# with, installs the casks, and passes.
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
mas install $WINDOWS_APP
mas get $WINDOWS_APP
$(printf 'brew install --cask %s\n' "${CASKS[@]}")" "$(installs)" "installs on a new Mac"
assert_not_contains "$(installs)" "$DATO" "installs on a new Mac"

# Signed in: a free app the Apple Account doesn't have comes from mas get, and one it has from mas
# install. A re-run installs nothing.
reset
touch "$SANDBOX/bundle-ok"
: > "$SANDBOX/mas-installed"
echo "$AMPHETAMINE" > "$SANDBOX/mas-owned"
echo "$WINDOWS_APP" > "$SANDBOX/mas-free"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_eq "mas install $AMPHETAMINE
mas install $WINDOWS_APP
mas get $WINDOWS_APP" "$(installs | grep '^mas')" "App Store installs when signed in"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "App Store apps already installed."
assert_contains "$RUN_OUTPUT" "Not installed, and optional: Dato."
assert_eq "" "$(installs)" "installs on a re-run"

# The bundle fails, and the App Store apps too: the App Store apps and casks are tried anyway, and
# the step fails with the bundle's status
reset
echo 1 > "$SANDBOX/bundle-status"
: > "$SANDBOX/mas-installed"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_eq "brew bundle install --no-upgrade
mas install $AMPHETAMINE
mas get $AMPHETAMINE
mas install $WINDOWS_APP
mas get $WINDOWS_APP
$(printf 'brew install --cask %s\n' "${CASKS[@]}")" "$(installs)" "installs after a failed bundle"

# Without mas, as when the bundle that installs it failed, the step fails, naming why
reset
echo 1 > "$SANDBOX/bundle-status"
: > "$SANDBOX/mas-installed"
subtest eval 'hide mas; assert_exit 1 main; assert_contains "$RUN_OUTPUT" "mas isn'"'"'t installed"'

# Ctrl-C in mas stops the step there, before the casks
reset
touch "$SANDBOX/bundle-ok"
: > "$SANDBOX/mas-installed"
echo 130 > "$SANDBOX/mas-status"
assert_exit 130 main
assert_eq "mas install $AMPHETAMINE" "$(installs)" "installs before Ctrl-C in mas"

# One cask fails: the rest install, and the step fails naming it
reset
touch "$SANDBOX/bundle-ok"
echo "zed=1" > "$SANDBOX/cask-status"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "These casks failed to install: zed."
assert_eq "${#CASKS[@]}" "$(installs | grep -c 'install --cask')" "casks tried"
assert_eq "$((${#CASKS[@]} - 1))" "$(wc -l < "$SANDBOX/casks" | tr -d ' ')" "casks installed"

# Re-run with zed fixed: only zed installs
: > "$SANDBOX/cask-status"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "brew install --cask zed" "$(installs)" "installs on a re-run"
assert_contains "$RUN_OUTPUT" "Brew formulae already installed."

# brew lists raycast, but its app was deleted: the step reinstalls it
rm -rf "$SANDBOX/apps/raycast.app"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "brew reinstall --cask raycast" "$(installs)" "installs with raycast's app deleted"
assert_contains "$RUN_OUTPUT" "brew lists raycast, but its app is gone; reinstalling it..."
[ -d "$SANDBOX/apps/raycast.app" ] || fail "raycast's app wasn't reinstalled"

# Ctrl-C in a cask install stops the step there
reset
touch "$SANDBOX/bundle-ok"
echo "zed=130" > "$SANDBOX/cask-status"
assert_exit 130 main
assert_eq "$(printf 'brew install --cask %s\n' font-monaspace ghostty zed)" "$(installs)" "installs before Ctrl-C"

# Ctrl-C in the bundle skips the casks
reset
echo 130 > "$SANDBOX/bundle-status"
assert_exit 130 main
assert_eq "brew bundle install --no-upgrade" "$(installs)" "installs after Ctrl-C in the bundle"

# Ubuntu
is_macos() { false; }
is_ubuntu() { true; }
locale_installed() { true; }

# Missing apt packages, declined: the step stops and prints the command
reset
missing_ubuntu_commands() { echo " jq"; }
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Missing commands: jq"
assert_contains "$RUN_OUTPUT" "Install them with: sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $UBUNTU_PACKAGES"
assert_file_not_contains "$STUB_LOG" "sudo"
assert_eq "" "$(installs)" "brew installs without the apt packages"

# apt-get update fails at once while apt-daily holds the lists lock, so it's retried a few times,
# and only for that. sudo runs apt-get, which fails with the lock error the number of times in
# $SANDBOX/locked, or with another error while $SANDBOX/apt-broken exists.
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
# Fewer tries than the step's, so the still-locked case runs fewer stubs, but enough for two lock
# failures then a success
# shellcheck disable=SC2034 # apt_get_update reads them
APT_UPDATE_RETRY_DELAY=0 APT_UPDATE_TRIES=4
updates() { grep -c "^apt-get .* update$" "$STUB_LOG" || true; }
missing_ubuntu_commands() { echo " jq"; }
reset
echo 2 > "$SANDBOX/locked"
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_eq 3 "$(updates)" "apt-get updates after two lock failures"
assert_contains "$RUN_OUTPUT" "apt's lists lock is held"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y $UBUNTU_PACKAGES"
# Still locked after every try: the step fails
reset
echo 100 > "$SANDBOX/locked"
assert_exit 1 main
assert_eq "$APT_UPDATE_TRIES" "$(updates)" "apt-get updates while the lock stays held"
assert_file_not_contains "$STUB_LOG" "install -y $UBUNTU_PACKAGES"
# Another failure isn't retried, and its error shows
reset
rm -f "$SANDBOX/locked"
touch "$SANDBOX/apt-broken"
assert_exit 1 main
assert_eq 1 "$(updates)" "apt-get updates after another error"
assert_contains "$RUN_OUTPUT" "does not have a Release file"
rm "$SANDBOX/apt-broken"
stub sudo 'exit 0'
unset DOTFILES_ASSUME_YES

# Approved: apt installs them, and the Ubuntu casks install, refreshing the font cache
reset
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update"
assert_file_contains "$STUB_LOG" "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y $UBUNTU_PACKAGES"
assert_contains "$RUN_OUTPUT" "Installing brew formulae..." "Ubuntu output"
assert_eq "$(printf 'brew bundle install --no-upgrade\n'; printf 'brew install --cask %s\n' "${UBUNTU_CASKS[@]}")" "$(installs)" "installs on Ubuntu"
assert_file_contains "$STUB_LOG" "fc-cache -f $FONTS"

unset DOTFILES_ASSUME_YES

# Re-run: no cask installs, so no cache refresh
missing_ubuntu_commands() { :; }
: > "$STUB_LOG"
touch "$SANDBOX/bundle-ok"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "apt packages already installed."
assert_contains "$RUN_OUTPUT" "Brew casks already installed."
assert_file_not_contains "$STUB_LOG" "fc-cache"
assert_file_not_contains "$STUB_LOG" "sudo"

# With XDG_DATA_HOME set, Homebrew puts fonts under it, and that's the dir refreshed
reset
export XDG_DATA_HOME="$SANDBOX/data"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "fc-cache -f $XDG_DATA_HOME/fonts"
unset XDG_DATA_HOME

# Installer casks have pkg artifacts but no app artifact, so CASK_PKG_APPS names their apps: a
# deleted one is reinstalled, and cask_state reports it gone
is_macos() { true; }
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

# An app installed outside Homebrew, such as Chrome from google.com, counts as installed: nothing
# to install, so no header, and no brew call for it
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
