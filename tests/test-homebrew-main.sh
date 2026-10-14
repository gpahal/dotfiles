#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The homebrew step's main: the Command Line Tools on macOS and the apt packages on Ubuntu come
# first, a failed bundle still installs the casks, one failed cask doesn't stop the rest, an app
# installed outside Homebrew counts as installed, Ctrl-C (exit 130 from brew) stops the step, the
# App Store hint shows only when an App Store app or mas is missing, apt-get update is retried only
# while another update holds apt's lists lock, Ubuntu refreshes the font cache after any cask
# install, and a re-run installs nothing. test-homebrew-install.sh covers installing Homebrew
# itself.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script homebrew/install.sh
# No app path for a cask brew doesn't list, so nothing asks brew info or finds the real Mac's apps
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=()
cask_app_path() { :; }
FONTS="$HOME/.local/share/fonts"

# brew: the bundle is installed when $SANDBOX/bundle-ok exists, everything but its App Store apps
# when $SANDBOX/rest-ok exists and HOMEBREW_BUNDLE_MAS_SKIP names all their ids, and bundle
# install exits with $SANDBOX/bundle-status. The casks in $SANDBOX/casks are installed, each with its app at
# $SANDBOX/apps/<cask>.app. Installing one exits with the status after its name in
# $SANDBOX/cask-status, creates its app, and for font-monaspace adds a font where Homebrew would.
stub brew 'S="'"$SANDBOX"'"
app_json() { printf "{\"token\": \"%s\", \"artifacts\": [{\"app\": [\"x.app\"], \"target\": \"%s\"}]}" "$1" "$S/apps/$1.app"; }
case "$1 $2" in
    "bundle check")
        [ -e "$S/bundle-ok" ] || { [ -e "$S/rest-ok" ] &&
            [ "${HOMEBREW_BUNDLE_MAS_SKIP:-}" == "937984704 1470584107 1295203466 " ]; } ;;
    "bundle install") exit "$(cat "$S/bundle-status" 2>/dev/null || echo 0)" ;;
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
stub xcode-select
stub fc-cache
stub sudo 'exit 0'
reset() {
    rm -rf "$SANDBOX/bundle-ok" "$SANDBOX/rest-ok" "$SANDBOX/bundle-status" "$SANDBOX/apps" "$FONTS"
    : > "$SANDBOX/casks"
    : > "$SANDBOX/cask-status"
    : > "$STUB_LOG"
}
installs() {
    grep -E '^brew (bundle install|install|reinstall)' "$STUB_LOG" | sed 's/ --file=[^ ]*//' || true
}

is_macos() { true; }
is_ubuntu() { false; }
stub uname 'if [ "$1" == -m ]; then echo arm64; else exec /usr/bin/uname "$@"; fi'

# An Intel Mac: the step fails before it installs anything
stub uname 'if [ "$1" == -m ]; then echo x86_64; else exec /usr/bin/uname "$@"; fi'
reset
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Intel Macs aren't supported"
assert_eq "uname -m" "$(cat "$STUB_LOG")" "commands run on an Intel Mac"
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

# The bundle fails on an App Store app not yet owned, and on a formula too: the casks install
# anyway, the step fails, and the App Store hint names sudo, which mas 7 installs with
reset
echo 1 > "$SANDBOX/bundle-status"
stub mas '[ "$1" != list ] || printf " 937984704  Amphetamine  (5.3.2)\n"'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_contains "$RUN_OUTPUT" "sudo -v"
assert_eq "brew bundle install --no-upgrade
$(printf 'brew install --cask %s\n' "${CASKS[@]}")" "$(installs)" "installs after a failed bundle"

# On a new Mac, the App Store apps are all the bundle couldn't install: the step warns with the
# sign-in steps and passes, and the casks install
reset
echo 1 > "$SANDBOX/bundle-status"
touch "$SANDBOX/rest-ok"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Everything else in the Brewfile is installed"
assert_contains "$RUN_OUTPUT" "Sign in to the App Store"
assert_eq "brew bundle install --no-upgrade
$(printf 'brew install --cask %s\n' "${CASKS[@]}")" "$(installs)" "installs with only the App Store apps missing"

# The bundle fails with every App Store app installed, e.g. on a formula: no App Store hint
reset
echo 1 > "$SANDBOX/bundle-status"
stub mas '[ "$1" != list ] || printf " 937984704  Amphetamine  (5.3.2)\n1470584107  Dato         (5.8.3)\n1295203466  Windows App  (11.2.1)\n"'
assert_exit 1 main
assert_not_contains "$RUN_OUTPUT" "Sign in to the App Store"

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
assert_contains "$RUN_OUTPUT" "Brew formulae and App Store apps already installed."

# Everything installed: nothing to do, with one brew call for every cask's app
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "" "$(installs)" "installs with everything installed"
assert_eq "brew info --json=v2 --installed --cask" "$(grep '^brew info' "$STUB_LOG")" "brew info calls"

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
# $SANDBOX/locked, or with another error while $SANDBOX/apt-broken exists, or with a permission
# error on the lock while $SANDBOX/apt-denied exists.
stub sudo 'exec env "$@"'
stub apt-get 'S="'"$SANDBOX"'"
[ "${*: -1}" == update ] || exit 0
if [ -e "$S/apt-broken" ]; then
    echo "E: The repository http://example.invalid resolute Release does not have a Release file." >&2
    exit 100
fi
if [ -e "$S/apt-denied" ]; then
    echo "E: Could not open lock file /var/lib/apt/lists/lock - open (13: Permission denied)" >&2
    echo "E: Unable to lock directory /var/lib/apt/lists/" >&2
    exit 100
fi
n="$(cat "$S/locked" 2>/dev/null || echo 0)"
[ "$n" -gt 0 ] || exit 0
echo $((n - 1)) > "$S/locked"
echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 812 (apt-get)" >&2
echo "E: Unable to lock directory /var/lib/apt/lists/" >&2
exit 100'
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0
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
# Nor is an error that names the lock without another update holding it
reset
touch "$SANDBOX/apt-denied"
assert_exit 1 main
assert_eq 1 "$(updates)" "apt-get updates after a permission error on the lock"
assert_not_contains "$RUN_OUTPUT" "apt's lists lock is held"
rm "$SANDBOX/apt-denied"
# apt-get update's progress shows as it runs, not only once it exits: the stub prints a line, then
# waits for the test to see it
stub apt-get 'echo "Get:1 http://example.invalid resolute InRelease"
for _ in $(seq 50); do
    [ ! -e "'"$SANDBOX"'/progress-seen" ] || exit 0
    sleep 0.1
done
exit 1'
rm -f "$SANDBOX/progress-seen"
apt_get_update > "$SANDBOX/progress" 2>&1 &
progress_pid=$!
for _ in $(seq 50); do
    ! grep -q "Get:1" "$SANDBOX/progress" || { touch "$SANDBOX/progress-seen"; break; }
    sleep 0.1
done
wait "$progress_pid" || fail "apt_get_update's output didn't show until apt-get update exited"
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

# A cask with no fonts installs: the cache is still refreshed
grep -vx zed "$SANDBOX/casks" > "$SANDBOX/casks.new" && mv "$SANDBOX/casks.new" "$SANDBOX/casks"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "brew install --cask zed" "$(installs)" "installs with zed missing"
assert_file_contains "$STUB_LOG" "fc-cache -f $FONTS"

# A missing locale is reported, but doesn't fail the step
locale_installed() { false; }
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The ubuntu step"
locale_installed() { true; }

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

# mas itself missing, e.g. when the bundle failed before installing it: the App Store hint shows
is_macos() { true; }
stub brew '[ "$1 $2" != "bundle install" ] || exit 1; [ "$1 $2" != "bundle check" ]'
hide mas
assert_exit 1 install_bundle
assert_contains "$RUN_OUTPUT" "Sign in to the App Store"
test_done
