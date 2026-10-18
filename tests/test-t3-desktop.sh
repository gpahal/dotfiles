#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# os: macos

# The T3 Code desktop app's setup on macOS. configure_t3_code writes the LaunchAgent that sets
# telemetry off in launchd's environment and then opens T3 Code at login, runs launchctl setenv
# now, without loading the agent, and sets the settings only once the app is quit. It touches no
# Login Items: osascript, a sentinel, fails the test if it runs. launchctl, pgrep, and brew are
# stubbed.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/t3-code/install.sh

# macOS
is_macos() { true; }
is_ubuntu() { false; }
APP="$SANDBOX/Applications/T3 Code (Beta).app"
mkdir -p "$APP"
t3_code_app_path() { echo "$APP"; }
# launchd's environment is in $SANDBOX/launchd-env: setenv writes the value, and getenv prints it
stub_launchd() {
    # shellcheck disable=SC2016 # expanded by the stub
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

# The LaunchAgent is written, sets the variable and then opens T3 Code by its bundle id, and
# launchd gets the variable now. The agent isn't loaded, which would open T3 Code, and Login
# Items aren't touched. The settings are set.
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

# launchd lost the variable, as after `launchctl unsetenv`: status says so, and a re-run sets it
# again
rm "$SANDBOX/launchd-env"
run status
assert_contains "$RUN_OUTPUT" "missing    $ENV_ITEM"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code
assert_file_contains "$STUB_LOG" "launchctl setenv T3CODE_TELEMETRY_ENABLED false"

# A LaunchAgent edited by hand counts as missing, and a re-run backs it up and replaces it
printf '%s\n' "$DIFFERENT_AGENT" > "$T3_CODE_TELEMETRY_AGENT"
run status
assert_contains "$RUN_OUTPUT" "missing    $AGENT_ITEM was edited since setup installed it"
assert_exit 0 configure_t3_code
assert_exit 0 cmp -s "$DOTFILES_DIR/ai_tools/t3-code/dotfiles.t3code-telemetry-off.plist" "$T3_CODE_TELEMETRY_AGENT"
assert_eq "$DIFFERENT_AGENT" "$(cat "$T3_CODE_TELEMETRY_AGENT.bak")" "the edited LaunchAgent's backup"

# launchctl can't set the variable: the settings still go on, and the step fails after them, also
# where a caller's || turns set -e off
rm "$SANDBOX/launchd-env" "$T3_CODE_SETTINGS" "$T3_CODE_CLIENT_SETTINGS"
stub launchctl '[ "$1" != setenv ] || exit 7'
assert_exit 1 configure_t3_code
assert_contains "$RUN_OUTPUT" "Couldn't set T3CODE_TELEMETRY_ENABLED"
assert_eq claude-opus-5-5 "$(jq -r .defaultModelSelection.model "$T3_CODE_SETTINGS")" \
    "the default model after a failed launchctl setenv"
assert_exit 1 eval 'configure_t3_code || exit 1'
# Once launchctl works, a re-run sets it
stub_launchd
assert_exit 0 configure_t3_code
assert_eq false "$(cat "$SANDBOX/launchd-env")" "launchd's T3CODE_TELEMETRY_ENABLED"

# A re-run changes nothing
: > "$STUB_LOG"
assert_exit 0 configure_t3_code
assert_contains "$RUN_OUTPUT" "$T3_CODE_TELEMETRY_AGENT is already up to date"
assert_contains "$RUN_OUTPUT" "Telemetry is already off in launchd's environment"
assert_contains "$RUN_OUTPUT" "settings are already set"
assert_file_not_contains "$STUB_LOG" "launchctl setenv"
# The LaunchAgent an earlier version of the step wrote, with no record of installing it, has the
# repo file's bytes, so it's recorded without a backup
rm -f "$INSTALLED_FILES" "$T3_CODE_TELEMETRY_AGENT".bak*
assert_exit 0 configure_t3_code
assert_contains "$RUN_OUTPUT" "$T3_CODE_TELEMETRY_AGENT is already up to date"
installed_unedited "$T3_CODE_TELEMETRY_AGENT" || fail "the earlier LaunchAgent wasn't recorded"
[ ! -e "$T3_CODE_TELEMETRY_AGENT.bak" ] || fail "the earlier LaunchAgent was backed up"

# The app isn't installed: the agent and the settings are still set
t3_code_app_path() { return 1; }
rm "$T3_CODE_SETTINGS" "$T3_CODE_TELEMETRY_AGENT"
assert_exit 0 configure_t3_code
[ -f "$T3_CODE_TELEMETRY_AGENT" ] || fail "the LaunchAgent wasn't written without the app"
assert_eq claude-opus-5-5 "$(jq -r .defaultModelSelection.model "$T3_CODE_SETTINGS")" "the default model without the app"

# The app is running, and there's no terminal to ask about quitting it: the settings wait
t3_code_app_path() { echo "$APP"; }
running_inside() { return 1; }
stub pgrep
rm "$T3_CODE_SETTINGS"
assert_exit 0 configure_t3_code
assert_contains "$RUN_OUTPUT" "T3 Code (Beta) is running; skipping."
[ ! -e "$T3_CODE_SETTINGS" ] || fail "the settings were written while T3 Code ran"

# When brew info fails, the report still runs
load_script ai_tools/t3-code/install.sh
is_macos() { true; }
is_ubuntu() { false; }
stub brew '[ "$1" != info ] || exit 1'
run status
assert_contains "$RUN_OUTPUT" "t3-code (cask)"
assert_contains "$RUN_OUTPUT" "Server settings in ~/.t3/userdata/settings.json"

# The app renamed itself as it updated, before the cask caught up, as when T3 Code drops its
# release stage: it counts as installed, not gone, so setup doesn't reinstall the cask's app beside
# it. The nightly build doesn't count.
# shellcheck disable=SC2016 # expanded by the stub
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
# Without it, the cask's app is gone, and setup reinstalls it
rm -r "$SANDBOX/Applications/T3 Code.app"
run status
assert_contains "$RUN_OUTPUT" "missing    t3-code (cask): brew lists it, but its app is gone"
test_done
