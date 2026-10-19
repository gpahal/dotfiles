#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# T3 Code's macOS setup. osascript is a sentinel, so touching Login Items fails the test.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/t3-code/install.sh

as_os macos
APP="$SANDBOX/Applications/T3 Code (Beta).app"
mkdir -p "$APP"
replace_fn t3_code_app_path 'echo "$APP"'
stub_launchd() {
    stub launchctl 'case "$1" in
    setenv) echo "$3" > "'"$SANDBOX"'/launchd-env" ;;
    getenv) cat "'"$SANDBOX"'/launchd-env" 2>/dev/null || true ;;
esac'
}
stub_launchd
stub pgrep 'exit 1'
DIFFERENT_AGENT='<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dotfiles.t3code-telemetry-off</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/true</string>
    </array>
</dict>
</plist>'
# shellcheck disable=SC2088 # as status shows it
AGENT_ITEM="~/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist"
ENV_ITEM="T3 Code's telemetry off in launchd's environment"

# Loading the agent would open T3 Code, so it's only written
assert_exit 0 configure_t3_code
assert_file_contains "$T3_CODE_TELEMETRY_AGENT" "<string>dotfiles.t3code-telemetry-off</string>"
assert_file_contains "$T3_CODE_TELEMETRY_AGENT" "<string>/bin/launchctl setenv T3CODE_TELEMETRY_ENABLED false; exec /usr/bin/open --env T3CODE_TELEMETRY_ENABLED=false -b com.t3tools.t3code</string>"
assert_file_contains "$T3_CODE_TELEMETRY_AGENT" "<key>RunAtLoad</key>"
if command -v plutil &>/dev/null; then
    plutil -lint "$T3_CODE_TELEMETRY_AGENT" > /dev/null || fail "the LaunchAgent isn't a valid plist"
fi
assert_file_contains "$STUB_LOG" "launchctl setenv T3CODE_TELEMETRY_ENABLED false"
assert_file_not_contains "$STUB_LOG" "launchctl load"
assert_file_not_contains "$STUB_LOG" "launchctl bootstrap"
assert_file_not_contains "$STUB_LOG" "osascript"
assert_contains "$RUN_OUTPUT" "Turned off telemetry"
assert_contains "$RUN_OUTPUT" "Copied ai_tools/t3-code/dotfiles.t3code-telemetry-off.plist to $T3_CODE_TELEMETRY_AGENT"
assert_eq claude-opus-5-5 "$(jq -r .defaultModelSelection.model "$T3_CODE_SETTINGS")" "the default model"
assert_eq steer "$(jq -r .followUpBehavior "$T3_CODE_CLIENT_SETTINGS")" "the follow-up behavior"
stub brew
run status
assert_contains "$RUN_OUTPUT" "ok         $AGENT_ITEM"
assert_contains "$RUN_OUTPUT" "ok         $ENV_ITEM"

rm "$SANDBOX/launchd-env"
run status
assert_contains "$RUN_OUTPUT" "missing    $ENV_ITEM"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code
assert_file_contains "$STUB_LOG" "launchctl setenv T3CODE_TELEMETRY_ENABLED false"

printf '%s\n' "$DIFFERENT_AGENT" > "$T3_CODE_TELEMETRY_AGENT"
run status
assert_contains "$RUN_OUTPUT" "missing    $AGENT_ITEM differs from the repo's"
assert_exit 0 configure_t3_code
assert_exit 0 cmp -s "$DOTFILES_DIR/ai_tools/t3-code/dotfiles.t3code-telemetry-off.plist" "$T3_CODE_TELEMETRY_AGENT"

# A failed setenv fails the step after the settings, even under a caller's ||
rm "$SANDBOX/launchd-env" "$T3_CODE_SETTINGS" "$T3_CODE_CLIENT_SETTINGS"
stub launchctl '[ "$1" != setenv ] || exit 7'
assert_exit 1 configure_t3_code
assert_contains "$RUN_OUTPUT" "Couldn't set T3CODE_TELEMETRY_ENABLED"
assert_eq claude-opus-5-5 "$(jq -r .defaultModelSelection.model "$T3_CODE_SETTINGS")" \
    "the default model after a failed launchctl setenv"
assert_exit 1 eval 'configure_t3_code || exit 1'
stub_launchd
assert_exit 0 configure_t3_code
assert_eq false "$(cat "$SANDBOX/launchd-env")" "launchd's T3CODE_TELEMETRY_ENABLED"

: > "$STUB_LOG"
assert_exit 0 configure_t3_code
assert_contains "$RUN_OUTPUT" "$T3_CODE_TELEMETRY_AGENT is already up to date"
assert_contains "$RUN_OUTPUT" "Telemetry is already off in launchd's environment"
assert_contains "$RUN_OUTPUT" "settings are already set"
assert_file_not_contains "$STUB_LOG" "launchctl setenv"

replace_fn t3_code_app_path 'return 1'
rm "$T3_CODE_SETTINGS" "$T3_CODE_TELEMETRY_AGENT"
assert_exit 0 configure_t3_code
[ -f "$T3_CODE_TELEMETRY_AGENT" ] || fail "the LaunchAgent wasn't written without the app"
assert_eq claude-opus-5-5 "$(jq -r .defaultModelSelection.model "$T3_CODE_SETTINGS")" "the default model without the app"

replace_fn t3_code_app_path 'echo "$APP"'
replace_fn running_inside 'return 1'
stub pgrep
rm "$T3_CODE_SETTINGS"
assert_exit 0 configure_t3_code
assert_contains "$RUN_OUTPUT" "T3 Code (Beta) is running; skipping."
[ ! -e "$T3_CODE_SETTINGS" ] || fail "the settings were written while T3 Code ran"

load_script ai_tools/t3-code/install.sh
as_os macos
stub brew '[ "$1" != info ] || exit 1'
run status
assert_contains "$RUN_OUTPUT" "t3-code (cask)"
assert_contains "$RUN_OUTPUT" "Server settings in ~/.t3/userdata/settings.json"

# An app renamed by an update before the cask caught up counts as installed; Nightly doesn't
stub brew 'case "$1" in
    info) printf "{\"casks\":[{\"artifacts\":[{\"app\":[\"%s\"],\"target\":\"%s\"}]}]}\n" "${APP##*/}" "'"$APP"'" ;;
esac'
mv "$APP" "$SANDBOX/Applications/T3 Code.app"
mkdir -p "$SANDBOX/Applications/T3 Code (Nightly).app"
assert_eq "$SANDBOX/Applications/T3 Code.app" "$(t3_code_app_path)" "the renamed app's path"
run status
assert_contains "$RUN_OUTPUT" "ok         t3-code (cask), as T3 Code.app"
: > "$STUB_LOG"
run main
assert_contains "$RUN_OUTPUT" "t3-code already installed, as T3 Code.app."
assert_file_not_contains "$STUB_LOG" "brew reinstall"
assert_file_not_contains "$STUB_LOG" "brew install"
rm -r "$SANDBOX/Applications/T3 Code.app"
: > "$STUB_LOG"
run status
assert_contains "$RUN_OUTPUT" "missing    t3-code (cask): brew lists it, but its app is gone"
: > "$STUB_LOG"
run main
assert_file_contains "$STUB_LOG" "brew reinstall"
mkdir -p "$APP"
: > "$STUB_LOG"
run main
assert_contains "$RUN_OUTPUT" "t3-code already installed."
run status
assert_contains "$RUN_OUTPUT" "ok         t3-code (cask)"
rm -r "$APP"
mkdir -p "$SANDBOX/Applications/T3 Code.app"
stub brew 'case "$1" in
    list) exit 1 ;;
    info) printf "{\"casks\":[{\"artifacts\":[{\"app\":[\"%s\"],\"target\":\"%s\"}]}]}\n" "${APP##*/}" "'"$APP"'" ;;
esac'
run status
assert_contains "$RUN_OUTPUT" "ok         t3-code (cask), installed outside Homebrew"
: > "$STUB_LOG"
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
