#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"
load_script homebrew/install.sh
export DOTFILES_STATUS_QUICK=1
replace_fn command_line_tools_installed 'return 0'
# zed is installed outside Homebrew; vicinae's app was deleted
mkdir -p "$SANDBOX/Zed.app" "$SANDBOX/Ghostty.app"
zed_outside_homebrew() {
    [ "$1" != zed ] || echo "$SANDBOX/Zed.app"
}
# shellcheck disable=SC2034 # cask_state reads it
CASK_PKG_APPS=()
eval "real_$(declare -f cask_app_path)"
replace_fn cask_app_path 'zed_outside_homebrew "$1"'
stub brew 'S="'"$SANDBOX"'"
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

brew_calls() {
    grep -c '^brew ' "$STUB_LOG" || true
}

as_os macos
stub mas '[ "$1" != list ] || printf " 937984704  Amphetamine  (5.3.2)\n"'
run status
# One for every cask, and one for vicinae's install receipt
assert_eq 2 "$(brew_calls)" "brew calls on macOS"
assert_eq 1 "$(grep -c '^mas list' "$STUB_LOG")" "mas list calls on macOS"
assert_contains "$RUN_OUTPUT" "missing    App Store apps (sign in to the App Store, buy the paid ones there once, then re-run the homebrew step)"
assert_contains "$RUN_OUTPUT" "unverified Brewfile brew formulae (skipped by --quick"
assert_contains "$RUN_OUTPUT" "ok         ghostty (cask)"
assert_not_contains "$RUN_OUTPUT" "ghostty (cask), installed outside Homebrew"
assert_contains "$RUN_OUTPUT" "ok         font-monaspace (cask)"
assert_contains "$RUN_OUTPUT" "ok         zed (cask), installed outside Homebrew"
assert_contains "$RUN_OUTPUT" "missing    vicinae (cask): brew lists it, but its app is gone; run brew reinstall --cask vicinae"
assert_contains "$RUN_OUTPUT" "missing    rectangle (cask)"
assert_contains "$RUN_OUTPUT" "info       Dato (App Store) isn't installed. It's optional"

# A renamed app isn't gone while the app brew's install receipt recorded is there
mkdir -p "$SANDBOX/caskroom/t3-code/.metadata" "$SANDBOX/T3 Code (Alpha).app"
echo '{"uninstall_artifacts": [{"app": ["T3 Code (Alpha).app"]}]}' > "$SANDBOX/caskroom/t3-code/.metadata/INSTALL_RECEIPT.json"
listing="t3-code	$SANDBOX/T3 Code (Beta).app"
assert_eq "brew	$SANDBOX/T3 Code (Alpha).app" "$(cask_state t3-code "" "$listing")" "a cask whose app was renamed"
echo '{"uninstall_artifacts": [{"app": ["T3 Code (Alpha).app"]}, {"binary": ["t3"]}, {"uninstall": [{"quit": "com.t3"}]}]}' > "$SANDBOX/caskroom/t3-code/.metadata/INSTALL_RECEIPT.json"
assert_eq "brew	$SANDBOX/T3 Code (Alpha).app" "$(cask_state t3-code "" "$listing")" "a renamed cask whose uninstall does more"
rm -r "$SANDBOX/T3 Code (Alpha).app"
assert_eq "gone	$SANDBOX/T3 Code (Beta).app" "$(cask_state t3-code "" "$listing")" "a renamed cask whose app is gone"

stub mas '[ "$1" != list ] || printf " 937984704  Amphetamine  (5.3.2)\n1295203466  Windows App  (11.0)\n"'
run status
assert_contains "$RUN_OUTPUT" "ok         App Store apps"
assert_contains "$RUN_OUTPUT" "info       Dato (App Store) isn't installed. It's optional"

subtest eval 'hide mas; run status
assert_contains "$RUN_OUTPUT" "unknown    App Store apps: mas"
assert_not_contains "$RUN_OUTPUT" "sign in to the App Store"
assert_not_contains "$RUN_OUTPUT" "Dato"'

# brew info fails for an unlisted cask offline, or one removed upstream
replace_fn cask_app_path 'real_cask_app_path "$1"'
run status
assert_contains "$RUN_OUTPUT" "missing    zed (cask)"
assert_contains "$RUN_OUTPUT" "missing    the-unarchiver (cask)"
assert_contains "$RUN_OUTPUT" "logi-options+ (cask)"
replace_fn cask_app_path 'zed_outside_homebrew "$1"'

: > "$STUB_LOG"
as_os ubuntu
replace_fn missing_ubuntu_commands
# The ubuntu step reports the locale
replace_fn locale_installed 'return 1'
run status
assert_not_contains "$RUN_OUTPUT" "locale"
assert_eq "brew list --cask -1" "$(cat "$STUB_LOG")" "brew calls on Ubuntu"
assert_contains "$RUN_OUTPUT" "ok         font-monaspace (cask)"
assert_contains "$RUN_OUTPUT" "missing    zed (cask)"
assert_contains "$RUN_OUTPUT" "ok         apt packages Homebrew needs"
assert_not_contains "$RUN_OUTPUT" "rectangle"

: > "$STUB_LOG"
as_os ubuntu
replace_fn missing_ubuntu_commands "printf ' %s' build-essential locale-gen"
hide brew
run status
assert_eq 3 "$RUN_STATUS" "status's exit status without Homebrew"
assert_contains "$RUN_OUTPUT" "missing    apt packages Homebrew needs; missing commands: build-essential locale-gen"
assert_contains "$RUN_OUTPUT" "missing    Homebrew"
assert_contains "$RUN_OUTPUT" "unknown    Brewfile and casks: Homebrew isn't installed"
assert_eq "" "$(cat "$STUB_LOG")" "brew calls without Homebrew"
test_done
