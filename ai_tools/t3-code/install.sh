#!/bin/bash
set -euo pipefail

# Install the T3 Code desktop app, turn off its telemetry, open it at login, and set its
# settings. T3 Code must be quit first; when run interactively the script offers to quit it,
# otherwise it skips the settings.

# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

T3_CODE_SETTINGS="$HOME/.t3/userdata/settings.json"
T3_CODE_CLIENT_SETTINGS="$HOME/.t3/userdata/client-settings.json"
T3_CODE_TELEMETRY_AGENT="$HOME/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist"

# The app's name carries its release stage, and changes with it. Ask brew which app the t3-code
# cask installs, and otherwise take any /Applications/T3 Code*.app except the separate nightly
# build.
t3_code_app_path() {
    local app
    app="$(cask_app_path t3-code)"
    if [ -n "$app" ] && [ -d "$app" ]; then
        echo "$app"
        return 0
    fi
    for app in "/Applications/T3 Code"*.app; do
        if [ -d "$app" ] && [[ "$app" != *"(Nightly).app" ]]; then
            echo "$app"
            return 0
        fi
    done
    return 1
}

configure_t3_code() {
    echo "Configuring T3 Code..."
    local app_path app_name
    app_path="$(t3_code_app_path || true)"
    app_name="${app_path##*/}"
    app_name="${app_name%.app}"
    # Turn off anonymous usage telemetry. T3 Code only reads this from its environment, and an
    # app opened from the Dock or Finder gets the launchd environment, not the shell's, so a
    # LaunchAgent sets it at every login and launchctl sets it now.
    local agent
    agent="$(cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dotfiles.t3code-telemetry-off</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/launchctl</string>
        <string>setenv</string>
        <string>T3CODE_TELEMETRY_ENABLED</string>
        <string>false</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
)"
    if [ "$(cat "$T3_CODE_TELEMETRY_AGENT" 2>/dev/null)" == "$agent" ] &&
        [ "$(launchctl getenv T3CODE_TELEMETRY_ENABLED)" == "false" ]; then
        echo "  Telemetry is already off"
    else
        mkdir -p "$(dirname "$T3_CODE_TELEMETRY_AGENT")"
        printf '%s\n' "$agent" > "$T3_CODE_TELEMETRY_AGENT"
        launchctl setenv T3CODE_TELEMETRY_ENABLED false
        echo "  Turned off telemetry (restart T3 Code if it's running)"
    fi

    # Open at login: T3 Connect, which the phone app goes through, only runs while the app is
    # open. The first run asks to let the terminal control System Events.
    local login_items
    if [ -z "$app_path" ]; then
        echo "  T3 Code isn't installed; skipping open at login"
    elif ! login_items="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)"; then
        echo "  Couldn't read Login Items; skipping. Allow the terminal to control System Events in"
        echo "  System Settings → Privacy & Security → Automation, or add $app_name in"
        echo "  System Settings → General → Login Items."
    elif [[ ", $login_items, " == *", $app_name, "* ]]; then
        echo "  Already opens at login"
    elif osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$app_path\", hidden:false}" > /dev/null; then
        echo "  Set to open at login"
    else
        echo "  Couldn't add $app_name to Login Items; add it in System Settings → General → Login Items."
    fi

    # Server settings (Settings → General, Threads, Storage): new threads use Claude Opus 5.5 at
    # medium effort with the 1M context window, in auto mode, each in its own worktree; Add project
    # starts in ~/Dev; threads continue after an app update; inactive threads settle after 5
    # days; old worktrees, browser artifacts, and logs are cleaned up; pull requests start with
    # squash merge; commit and PR text follows custom instructions; Cursor, Grok, and OpenCode
    # are off. Worktrees start from the local base branch. Model options are set in place, so
    # any others and their order survive a re-run. Existing worktree setup actions wait for
    # completion. T3 has no global async default; update both current and legacy action lists.
    # shellcheck disable=SC2016 # jq variables, not shell ones
    local settings='
        (
            .defaultProjectScripts[]?,
            .projectSettingsOverrides[]?.defaultProjectScripts[]?,
            .projectScriptOverrides[]?[]?
        ) |= if .runOnWorktreeCreate == true then .async = false else . end
        | .defaultModelSelection.instanceId = "claudeAgent"
        | .defaultModelSelection.model = "claude-opus-5-5"
        | .defaultModelSelection.options |= reduce (
            {"id": "effort", "value": "medium"},
            {"id": "contextWindow", "value": "1m"}
          ) as $opt (. // [];
            if any(.[]; .id == $opt.id)
            then map(if .id == $opt.id then .value = $opt.value else . end)
            else . + [$opt]
            end
          )
        | .defaultRuntimeMode = "auto"
        | .defaultThreadEnvMode = "worktree"
        | .newWorktreesStartFromOrigin = false
        | .addProjectBaseDirectory = "~/Dev"
        | .continueThreadsAfterServerUpdate = true
        | .sidebarAutoSettleAfterDays = 5
        | .storageCleanup.worktreeAfterDays = 30
        | .storageCleanup.worktreeOnMerge = true
        | .storageCleanup.worktreeOnDelete = true
        | .storageCleanup.worktreeUnchanged = true
        | .storageCleanup.browserArtifactsAfterDays = 30
        | .storageCleanup.logsAfterDays = 30
        | .pullRequestMergeMethod = "squash"
        | .sourceControlWritingStyle = {
            "mode": "custom",
            "customInstructions": "Keep titles concise. Use short bullet points in the description."
          }
        | .providers.cursor.enabled = false
        | .providers.grok.enabled = false
        | .providers.opencode.enabled = false
    '
    # Desktop settings: system notifications with sound and in-app notifications, a message
    # sent mid-turn steers the running turn instead of queueing, and the sidebar's working shelf
    local client_settings='
        .notificationMode = "notifications-and-sound"
        | .inAppNotificationsEnabled = true
        | .followUpBehavior = "steer"
        | .sidebarWorkingShelfEnabled = true
    '
    if json_applied "$T3_CODE_SETTINGS" "$settings" &&
        json_applied "$T3_CODE_CLIENT_SETTINGS" "$client_settings"; then
        echo "  Model, thread, setup actions, cleanup, merge, writing style, provider, notification, and sidebar"
        echo "  settings are already set"
        return 0
    fi
    ensure_app_quit "${app_name:-T3 Code}" || return 0
    json_merge "$T3_CODE_SETTINGS" "$settings"
    json_merge "$T3_CODE_CLIENT_SETTINGS" "$client_settings"
    echo "  Set model, thread, setup actions, cleanup, merge, writing style, provider, notification, and sidebar"
    echo "  settings"
}

main() {
    echo "Setting up T3 Code..."
    install_cask t3-code "$(t3_code_app_path || true)"
    configure_t3_code
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
