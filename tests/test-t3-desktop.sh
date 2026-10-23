#!/bin/bash
# shellcheck disable=SC2329

# T3 Code's macOS setup: the telemetry LaunchAgent, written but not loaded, launchd's telemetry
# variable, the settings, and the cask, including an app an update renamed.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/t3-code/install.sh

as_os macos
APP="$SANDBOX/Applications/T3 Code (Beta).app"
mkdir -p "$APP"
replace_fn t3_code_app_path 'echo "$APP"'
stub_launchd() {
    stub launchctl 'case "$1" in
    setenv) echo "$3" > "$SANDBOX/launchd-env" ;;
    getenv) cat "$SANDBOX/launchd-env" 2>/dev/null || true ;;
esac'
}
stub_launchd
stub pgrep 'exit 1'
# shellcheck disable=SC2088 # as status shows it
AGENT_ITEM="~/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist"
ENV_ITEM="T3 Code's telemetry off in launchd's environment"

# Loading the agent would open T3 Code, so it's only written
assert_exit 0 configure_t3_code
# plutil comes with macOS, so only a run there lints the plist
if [ "$(uname -s)" == Darwin ]; then
    plutil -lint "$T3_CODE_TELEMETRY_AGENT" > /dev/null || fail "the LaunchAgent isn't a valid plist"
fi
assert_file_contains "$STUB_LOG" "launchctl setenv T3CODE_TELEMETRY_ENABLED false"
assert_file_not_contains "$STUB_LOG" "launchctl load"
assert_file_not_contains "$STUB_LOG" "launchctl bootstrap"
assert_eq claude-opus-5-5 "$(jq -r .defaultModelSelection.model "$T3_CODE_SETTINGS")" "the default model"
assert_eq steer "$(jq -r .followUpBehavior "$T3_CODE_CLIENT_SETTINGS")" "the follow-up behavior"
stub brew
run status
assert_contains "$RUN_OUTPUT" "ok         $AGENT_ITEM"
assert_contains "$RUN_OUTPUT" "ok         $ENV_ITEM"

assert_exit 0 configure_t3_code

# A running T3 Code keeps its settings
replace_fn running_inside 'return 1'
stub pgrep
rm "$T3_CODE_SETTINGS"
assert_exit 0 configure_t3_code
[ ! -e "$T3_CODE_SETTINGS" ] || fail "the settings were written while T3 Code ran"

# The real t3_code_app_path, which finds a renamed app
load_script ai_tools/t3-code/install.sh
as_os macos

# An app renamed by an update before the cask caught up counts as installed; Nightly doesn't
stub brew 'case "$1" in
    info) printf "{\"casks\":[{\"artifacts\":[{\"app\":[\"%s\"],\"target\":\"%s\"}]}]}\n" "${APP##*/}" "'"$APP"'" ;;
esac'
mv "$APP" "$SANDBOX/Applications/T3 Code.app"
mkdir -p "$SANDBOX/Applications/T3 Code (Nightly).app"
assert_eq "$SANDBOX/Applications/T3 Code.app" "$(t3_code_app_path)" "the renamed app's path"
run status
assert_contains "$RUN_OUTPUT" "ok         t3-code (cask), as T3 Code.app"
run main
assert_contains "$RUN_OUTPUT" "t3-code already installed, as T3 Code.app."
assert_file_not_contains "$STUB_LOG" "brew reinstall"
assert_file_not_contains "$STUB_LOG" "brew install"
stub brew 'case "$1" in
    list) exit 1 ;;
    info) printf "{\"casks\":[{\"artifacts\":[{\"app\":[\"%s\"],\"target\":\"%s\"}]}]}\n" "${APP##*/}" "'"$APP"'" ;;
esac'
run status
assert_contains "$RUN_OUTPUT" "ok         t3-code (cask), installed outside Homebrew"
run main
assert_contains "$RUN_OUTPUT" "t3-code already installed, but not by Homebrew"
assert_file_not_contains "$STUB_LOG" "brew install"

# Without jq, the cask's state depends on this machine's /Applications, so it isn't asserted
no_jq_status() {
    hide jq
    run status
    assert_contains "$RUN_OUTPUT" "t3-code (cask)"
    assert_not_contains "$RUN_OUTPUT" "command not found"
    assert_contains "$RUN_OUTPUT" "ok         $AGENT_ITEM"
    assert_contains "$RUN_OUTPUT" "ok         $ENV_ITEM"
    assert_contains "$RUN_OUTPUT" "unknown    T3 Code's settings: $(missing_cmd_hint jq)"
    assert_not_contains "$RUN_OUTPUT" "Server settings"
}
subtest no_jq_status

test_done
