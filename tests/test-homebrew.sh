#!/bin/bash

# The homebrew step: installing Homebrew, the Brewfile, casks, App Store apps, and apt packages,
# and its status.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# cask_state reads brew's JSON with jq
command -v jq &> /dev/null || skip "jq isn't installed"

# --- installing Homebrew ---

install_without_terminal() {
    load_script homebrew/install.sh
    hide brew
    replace_fn run_installer 'echo "run_installer $*" >> "$STUB_LOG"'
    replace_fn load_brew
    PREFIX="$SANDBOX/homebrew"
    replace_fn homebrew_prefix 'echo "$PREFIX"'
    for os in ubuntu macos; do
        as_os "$os"

        # No terminal, no prefix, sudo not cached
        : > "$STUB_LOG"
        stub sudo 'exit 1'
        assert_exit 1 install_homebrew
        assert_file_not_contains "$STUB_LOG" "run_installer"

        : > "$STUB_LOG"
        stub sudo 'exit 0'
        assert_exit 0 install_homebrew
        assert_file_contains "$STUB_LOG" "run_installer bash https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

        # An existing prefix needs no sudo
        : > "$STUB_LOG"
        stub sudo 'exit 1'
        mkdir -p "$PREFIX"
        assert_exit 0 install_homebrew
        assert_file_contains "$STUB_LOG" "run_installer bash"
        rmdir "$PREFIX"
    done
}
subtest install_without_terminal

# --- main ---

load_script homebrew/install.sh
# No app path for an unlisted cask, so nothing reads the real Mac's apps
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=()
replace_fn cask_app_path
FONTS="$HOME/.local/share/fonts"

stub brew 'S="$SANDBOX"
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
stub mas 'S="$SANDBOX"
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
stub_uname Darwin

reset
stub xcode-select '[ "$1" != -p ] || exit 2'
assert_exit 1 main
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
assert_contains "$RUN_OUTPUT" "optional: Dato"
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
assert_exit 0 main
assert_eq "" "$(installs)" "installs on a re-run"
assert_eq 1 "$(grep -c '^mas list' "$STUB_LOG")" "mas list calls on a re-run"
grep -vxF "$DATO" "$SANDBOX/mas-installed" > "$SANDBOX/mas-left" && mv "$SANDBOX/mas-left" "$SANDBOX/mas-installed"
: > "$SANDBOX/mas-owned"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "optional: Dato"
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
assert_contains "$RUN_OUTPUT" "failed to install: zed."
assert_eq "${#CASKS[@]}" "$(installs | grep -c 'install --cask')" "casks tried"
assert_eq "$((${#CASKS[@]} - 1))" "$(wc -l < "$SANDBOX/casks" | tr -d ' ')" "casks installed"

: > "$SANDBOX/cask-status"
assert_exit 0 main
assert_eq "brew install --cask zed" "$(installs)" "installs on a re-run"

rm -rf "$SANDBOX/apps/vicinae.app"
assert_exit 0 main
assert_eq "brew reinstall --cask vicinae" "$(installs)" "installs with vicinae's app deleted"
[ -d "$SANDBOX/apps/vicinae.app" ] || fail "vicinae's app wasn't reinstalled"

reset
echo 130 > "$SANDBOX/bundle-status"
assert_exit 130 main
assert_eq "brew bundle install --no-upgrade" "$(installs)" "installs after Ctrl-C in the bundle"

as_os ubuntu
replace_fn locale_installed 'return 0'

reset
replace_fn missing_ubuntu_commands 'echo " jq"'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Install them with: "
assert_file_not_contains "$STUB_LOG" "sudo"
assert_eq "" "$(installs)" "brew installs without the apt packages"

reset
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update"
assert_file_contains "$STUB_LOG" "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y $UBUNTU_PACKAGES"
assert_eq "$(printf 'brew bundle install --no-upgrade\n'; printf 'brew install --cask %s\n' "${UBUNTU_CASKS[@]}")" "$(installs)" "installs on Ubuntu"
assert_file_contains "$STUB_LOG" "fc-cache -f $FONTS"

answer no

replace_fn missing_ubuntu_commands
: > "$STUB_LOG"
touch "$SANDBOX/bundle-ok"
assert_exit 0 main
assert_eq "" "$(installs)" "installs on an Ubuntu re-run"
assert_file_not_contains "$STUB_LOG" "fc-cache"
assert_file_not_contains "$STUB_LOG" "sudo"

# Installer casks have no app artifact, so CASK_PKG_APPS names their apps
as_os macos
CASKS=(tailscale-app logi-options+)
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=("tailscale-app=$SANDBOX/apps/tailscale-app.app" "logi-options+=$SANDBOX/apps/logi-options+.app")
stub brew 'S="$SANDBOX"
case "$1 $2" in
    "list --cask") exit 0 ;;
    "info --json=v2") echo '\''{"casks":[{"token":"tailscale-app","artifacts":[{"pkg":["t.pkg"]}]},{"token":"logi-options+","artifacts":[{"pkg":["l.pkg"]}]}]}'\'' ;;
    "reinstall --cask") mkdir -p "$S/apps/$3.app" ;;
esac'
rm -rf "$SANDBOX/apps"
assert_exit 0 install_casks
assert_file_contains "$STUB_LOG" 'brew reinstall --cask tailscale-app'
assert_file_contains "$STUB_LOG" 'brew reinstall --cask logi-options+'
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
assert_exit 0 install_casks
assert_file_not_contains "$STUB_LOG" "outside"

# --- cask failures and missing_ubuntu_commands ---

# brew exits 130 on Ctrl-C, so install_cask exits rather than return a failure `|| result=1` hides.
# Other codes, 137, 141, and 255 included, return so the rest still install.
load_script homebrew/install.sh
as_os ubuntu
replace_fn cask_state "printf 'missing\t\n'"
# shellcheck disable=SC2034 # os_casks reads it
UBUNTU_CASKS=(foo bar)
direct() {
    install_cask foo "" || echo "returned $?"
}
for code in 130 143 129 1 137 141 255; do
    stub brew "exit $code"
    : > "$STUB_LOG"
    if ! interrupted_status "$code"; then
        assert_exit 1 install_casks
        assert_contains "$RUN_OUTPUT" "failed to install: foo bar."
    else
        assert_exit "$code" install_casks
        assert_not_contains "$RUN_OUTPUT" "failed to install"
        assert_file_not_contains "$STUB_LOG" "install --cask bar"
        assert_exit "$code" direct
        assert_not_contains "$RUN_OUTPUT" "returned"
    fi
done

# Only system dirs count, so the apt packages are installed even when Homebrew has the commands
mkdir -p "$SANDBOX/homebrew/bin"
printf '#!/bin/sh\n' > "$SANDBOX/homebrew/bin/dotfiles-test-cmd"
chmod +x "$SANDBOX/homebrew/bin/dotfiles-test-cmd"
# shellcheck disable=SC2034 # missing_ubuntu_commands reads it
UBUNTU_COMMANDS=(sh dotfiles-test-cmd)
missing="$(PATH="$SANDBOX/homebrew/bin:$PATH" missing_ubuntu_commands)"
assert_contains "$missing " " dotfiles-test-cmd " "missing commands with one only in Homebrew's dir"
assert_not_contains "$missing " " sh " "missing commands with one only in Homebrew's dir"

# --- status ---

load_script homebrew/install.sh
export DOTFILES_STATUS_FOR_ALERTS=1
replace_fn command_line_tools_installed 'return 0'
# zed is installed outside Homebrew; vicinae's app was deleted
mkdir -p "$SANDBOX/Zed.app" "$SANDBOX/Ghostty.app"
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=()
replace_fn cask_app_path '[ "$1" != zed ] || echo "$SANDBOX/Zed.app"'
stub brew 'S="$SANDBOX"
[ "$*" != "list --cask -1" ] || { printf "ghostty\nfont-monaspace\nvicinae\n"; exit; }
[ "$*" != --caskroom ] || { echo "$S/caskroom"; exit; }
[ "$*" == "info --json=v2 --installed --cask" ] || exit 1
cat << JSON
{"casks": [
    {"token": "ghostty", "artifacts": [{"uninstall": []}, {"app": ["Ghostty.app"], "target": "$S/Ghostty.app"}]},
    {"token": "font-monaspace", "artifacts": [{"font": ["a.otf"], "target": "$S/a.otf"}]},
    {"token": "vicinae", "artifacts": [{"app": ["Vicinae.app"], "target": "$S/Vicinae.app"}, ["x"]]}
]}
JSON'

as_os macos
stub mas '[ "$1" != list ] || printf " 937984704  Amphetamine  (5.3.2)\n"'
run status
# --for-alerts skips the slow bundle check
assert_file_not_contains "$STUB_LOG" "brew bundle"
assert_contains "$RUN_OUTPUT" "unverified Brewfile brew formulae"
assert_contains "$RUN_OUTPUT" "missing    App Store apps"
assert_contains "$RUN_OUTPUT" "ok         ghostty (cask)"
assert_not_contains "$RUN_OUTPUT" "ghostty (cask), installed outside Homebrew"
assert_contains "$RUN_OUTPUT" "ok         font-monaspace (cask)"
assert_contains "$RUN_OUTPUT" "ok         zed (cask), installed outside Homebrew"
assert_contains "$RUN_OUTPUT" "missing    vicinae (cask): brew lists it, but its app is gone"
assert_contains "$RUN_OUTPUT" "missing    rectangle (cask)"
assert_contains "$RUN_OUTPUT" "info       Dato (App Store)"

# A renamed app isn't gone while the app brew's install receipt recorded is there
mkdir -p "$SANDBOX/caskroom/t3-code/.metadata" "$SANDBOX/T3 Code (Alpha).app"
echo '{"uninstall_artifacts": [{"app": ["T3 Code (Alpha).app"]}]}' > "$SANDBOX/caskroom/t3-code/.metadata/INSTALL_RECEIPT.json"
listing="t3-code	$SANDBOX/T3 Code (Beta).app"
assert_eq "brew	$SANDBOX/T3 Code (Alpha).app" "$(cask_state t3-code "" "$listing")" "a cask whose app was renamed"
echo '{"uninstall_artifacts": [{"app": ["T3 Code (Alpha).app"]}, {"binary": ["t3"]}, {"uninstall": [{"quit": "com.t3"}]}]}' > "$SANDBOX/caskroom/t3-code/.metadata/INSTALL_RECEIPT.json"
assert_eq "brew	$SANDBOX/T3 Code (Alpha).app" "$(cask_state t3-code "" "$listing")" "a renamed cask whose uninstall does more"
rm -r "$SANDBOX/T3 Code (Alpha).app"
assert_eq "gone	$SANDBOX/T3 Code (Beta).app" "$(cask_state t3-code "" "$listing")" "a renamed cask whose app is gone"
# --renamed: an app that renamed itself before the cask caught up, beside where brew put it, but not
# one --except matches
mkdir -p "$SANDBOX/T3 Code (Nightly).app" "$SANDBOX/T3 Code.app"
renamed=(--renamed "T3 Code*.app" --except "*(Nightly).app")
assert_eq "renamed	$SANDBOX/T3 Code.app" "$(cask_state "${renamed[@]}" t3-code "" "$listing")" "a cask whose app renamed itself"
run status_cask "${renamed[@]}" t3-code "" "$listing"
assert_eq "  ok         t3-code (cask), as T3 Code.app" "$RUN_OUTPUT" "status of a cask whose app renamed itself"
run install_cask t3-code "$SANDBOX/T3 Code.app" renamed
assert_eq "  t3-code already installed, as T3 Code.app." "$RUN_OUTPUT" "installing a cask whose app renamed itself"
assert_eq "other	$SANDBOX/T3 Code.app" "$(cask_state "${renamed[@]}" t3-code "$SANDBOX/T3 Code (Beta).app" "")" \
    "a renamed app brew doesn't list"
rm -r "$SANDBOX/T3 Code.app"
assert_eq "gone	$SANDBOX/T3 Code (Beta).app" "$(cask_state "${renamed[@]}" t3-code "" "$listing")" "a cask with only the excepted app"
rm -r "$SANDBOX/T3 Code (Nightly).app"

: > "$STUB_LOG"
as_os ubuntu
replace_fn missing_ubuntu_commands "printf ' %s' build-essential locale-gen"
hide brew
run main --status
assert_eq 3 "$RUN_STATUS" "status's exit status without Homebrew"
assert_contains "$RUN_OUTPUT" "missing    apt packages Homebrew needs; missing commands: build-essential locale-gen"
assert_contains "$RUN_OUTPUT" "missing    Homebrew"
assert_contains "$RUN_OUTPUT" "unknown    Brewfile and casks: Homebrew isn't installed"
assert_eq "" "$(cat "$STUB_LOG")" "brew calls without Homebrew"
test_done
