#!/bin/bash
set -euo pipefail

# Set up AI tools:
#
# - Claude Code CLI
# - Claude desktop app
# - Codex CLI
# - ChatGPT desktop app
# - T3 Code desktop app
# - User-level instructions in ai_tools/user-instructions.md, for Claude Code and Codex
# - Skills in ai_tools/skills, for Claude Code and Codex
#
# Idempotent: safe to re-run. Apps whose config is edited (Claude, ChatGPT, T3 Code) must be
# quit first; when run interactively the script offers to quit them, otherwise it skips them.
#
# Things macOS doesn't allow scripts to change (notification alert style, Accessibility and
# Screen Recording permissions, installing browser extensions) are opened for you at the end.
# See ai_tools/README.md for the full checklist.

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

CLAUDE_CODE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
T3_CODE_APP="T3 Code (Alpha)"
T3_CODE_SETTINGS="$HOME/.t3/userdata/settings.json"
T3_CODE_CLIENT_SETTINGS="$HOME/.t3/userdata/client-settings.json"
T3_CODE_TELEMETRY_AGENT="$HOME/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist"
CLAUDE_CHROME_EXTENSION_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
NOTIFICATION_SETTINGS="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"

# ─── Helpers ───

is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

confirm() {
    local reply
    is_interactive || return 1
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# Before editing an existing file, ask whether to back it up to <file>.bak, unless <file>.bak
# already matches it
maybe_backup() {
    local prompt="  Back up $1 to $1.bak?"
    [ -f "$1" ] || return 0
    if [ -f "$1.bak" ]; then
        cmp -s "$1" "$1.bak" && return 0
        prompt="  Back up $1 to $1.bak (overwrites the existing $1.bak)?"
    fi
    if confirm "$prompt"; then
        cp "$1" "$1.bak"
        echo "  Backed up $1 to $1.bak"
    fi
}

# Succeeds when this script runs inside an app, e.g. in its built-in terminal
running_inside() {
    local pid=$$ comm
    while [ "${pid:-0}" -gt 1 ]; do
        comm="$(ps -o comm= -p "$pid")" || return 1
        [ "${comm##*/}" == "$1" ] && return 0
        pid="$(ps -o ppid= -p "$pid" | tr -d ' ')" || return 1
    done
    return 1
}

# Quit a running app (after asking). Returns non-zero if it is still running.
ensure_app_quit() {
    local app="$1"
    # pgrep takes a regex, so escape app names like "T3 Code (Alpha)". -a counts this script's
    # ancestors too.
    pgrep -ax "$(printf '%s' "$app" | sed 's/[][\.*^$()+?{}|]/\\&/g')" &>/dev/null || return 0
    if running_inside "$app"; then
        echo "  $app is running this script, so it can't be quit; skipping. Re-run this script from"
        echo "  another terminal."
        return 1
    fi
    if ! confirm "  $app is running and must be quit to change its settings. Quit $app now?"; then
        echo "  $app is running; skipping. Quit $app and re-run this script."
        return 1
    fi
    osascript -e "quit app \"$app\""
    for _ in $(seq 1 20); do
        pgrep -x "$app" &>/dev/null || return 0
        sleep 0.5
    done
    echo "  $app did not quit; skipping."
    return 1
}

# Succeeds when a jq expression wouldn't change a JSON file, i.e. its settings are already there
json_applied() {
    [ -s "$1" ] && jq -e "($2) == ." "$1" &>/dev/null
}

# Merge a jq expression into a JSON file, creating the file if needed
json_merge() {
    local file="$1" filter="$2" tmp
    maybe_backup "$file"
    mkdir -p "$(dirname "$file")"
    [ -s "$file" ] || echo '{}' > "$file"
    tmp="$(mktemp)"
    jq "$filter" "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Set `key = value` inside `[table]` of a TOML file, keeping the other lines (comments,
# ordering) untouched. An empty `table` means the top level, before the first table.
# `value` must already be a TOML literal, e.g. '"squash"' or 'true'.
toml_set() {
    local file="$1" table="$2" key="$3" value="$4" tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp="$(mktemp)"
    awk -v table="$table" -v key="$key" -v value="$value" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function is_header(s) { return s ~ /^[ \t]*\[/ }
        function flush_blanks() { for (; blanks > 0; blanks--) print "" }
        BEGIN { header = "[" table "]"; in_table = seen_table = (table == "") }
        {
            line = $0
            if (is_header(line)) {
                # Leaving the target table without finding the key: add it after its last entry
                if (in_table && !done) {
                    print key " = " value
                    done = 1
                    # Keep a blank line between new top-level keys and the first table
                    if (table == "" && blanks == 0) blanks = 1
                }
                flush_blanks()
                in_table = (table != "" && trim(line) == header)
                if (in_table) seen_table = 1
                print line
                next
            }
            if (in_table && trim(line) == "") { blanks++; next }
            flush_blanks()
            if (in_table && !done) {
                split(line, parts, "=")
                if (index(line, "=") > 0 && trim(parts[1]) == key) {
                    print key " = " value
                    done = 1
                    next
                }
            }
            print line
        }
        END {
            if (in_table && !done) { print key " = " value; done = 1 }
            flush_blanks()
            if (!seen_table) { print ""; print header; print key " = " value }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# ─── Install apps ───

install_apps() {
    echo "Installing AI apps..."
    local entry cask installed
    # cask:path it installs. The desktop apps auto-update, and may have been installed outside brew.
    for entry in \
        "claude:/Applications/Claude.app" \
        "chatgpt:/Applications/ChatGPT.app" \
        "t3-code:/Applications/$T3_CODE_APP.app" \
        "codex:$(brew --prefix)/bin/codex"; do
        cask="${entry%%:*}"
        installed="${entry#*:}"
        if brew list --cask "$cask" &>/dev/null || [ -e "$installed" ]; then
            echo "  $cask already installed."
        else
            echo "  Installing $cask..."
            brew install --cask "$cask"
        fi
    done

    # Claude Code: the native installer auto-updates, so prefer it over the claude-code cask
    if command -v claude &>/dev/null; then
        echo "  Claude Code already installed ($(claude --version))."
    else
        echo "  Installing Claude Code..."
        curl -fsSL https://claude.ai/install.sh | bash
    fi

    if [ ! -d "/Applications/Google Chrome.app" ]; then
        echo "  Google Chrome is not installed. Install it for browser control (see README manual steps)."
    fi
}

# ─── Claude Code (CLI) ───

configure_claude_code() {
    echo "Configuring Claude Code..."
    # /config → Push when actions required, Push when Claude decides
    #   (mobile push notifications through the Claude app while Remote Control is active)
    # Start new sessions in auto mode. Only user or managed settings can make auto the default.
    # Turn off auto memory.
    # Send Anthropic less: no telemetry, error reports, session quality surveys (they can
    #   attach the transcript), /feedback, or feedback drafts. Training on your chats is an
    #   account setting (see open_manual_steps). Leave CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    #   unset: it also turns off Remote Control, so mobile pushes stop.
    local settings='
        .inputNeededNotifEnabled = true
        | .agentPushNotifEnabled = true
        | .permissions.defaultMode = "auto"
        | .autoMemoryEnabled = false
        | .feedbackDrafts = "off"
        | .env.DO_NOT_TRACK = "1"
        | .env.DISABLE_ERROR_REPORTING = "1"
        | .env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1"
        | .env.DISABLE_FEEDBACK_COMMAND = "1"
    '
    if json_applied "$CLAUDE_CODE_SETTINGS" "$settings"; then
        echo "  Push notifications, auto mode, no auto memory, and the data-sharing opt-outs are"
        echo "  already set"
        return 0
    fi
    json_merge "$CLAUDE_CODE_SETTINGS" "$settings"
    echo "  Turned on push notifications and auto mode by default, turned off auto memory, and"
    echo "  opted out of telemetry, error reports, surveys, and feedback"
}

# ─── Claude desktop app ───

configure_claude_desktop() {
    echo "Configuring Claude desktop app..."
    # Settings → Claude Code:
    #   Draw attention on notifications → On
    #   Archive inactive sessions → 30 days
    #   Keep computer awake while Claude works → On
    #   Keep awake on battery power → On
    # Settings → General:
    #   Show in menu bar → Off (no menu bar icon, and no running in the background once the
    #   window is closed)
    # Also: Option+Space opens quick entry; scheduled tasks on in Code and Cowork; Cowork uses
    # browser tools in Chrome and web search, and keeps its files in ~/Documents/Claude.
    local files_dir="$HOME/Documents/Claude"
    local settings='
        .preferences.dockBounceEnabled = true
        | .preferences.ccAutoArchiveInactiveDays = 30
        | .preferences.ccKeepAwakeWhileWorking = true
        | .preferences.ccKeepAwakeOnBattery = true
        | .preferences.ccdScheduledTasksEnabled = true
        | .preferences.menuBarEnabled = false
        | .preferences.quickEntryShortcut = {"accelerator": "Alt+Space"}
        | .preferences.coworkBrowserToolsEnabled = true
        | .preferences.coworkPreferredBrowser = "chrome"
        | .preferences.coworkWebSearchEnabled = true
        | .preferences.coworkScheduledTasksEnabled = true
        | .coworkUserFilesPath = "'"$files_dir"'"
    '
    if json_applied "$CLAUDE_DESKTOP_CONFIG" "$settings"; then
        echo "  Notifications, keep-awake, archiving, menu bar, quick entry, and Cowork settings are"
        echo "  already set"
        return 0
    fi
    ensure_app_quit "Claude" || return 0
    mkdir -p "$files_dir"
    json_merge "$CLAUDE_DESKTOP_CONFIG" "$settings"
    echo "  Set notifications, keep-awake, archiving, no menu bar icon, Option+Space quick entry,"
    echo "  and Cowork browser, web search, scheduled tasks, and files folder ($files_dir)"
}

# ─── Codex (ChatGPT desktop app + Codex CLI) ───

# Write a copy of the Codex config with the settings applied, and print its path
codex_config_edited() {
    local edited
    edited="$(mktemp)"
    [ -f "$CODEX_CONFIG" ] && cp "$CODEX_CONFIG" "$edited"

    # Short answers and reasoning summaries
    toml_set "$edited" '' model_verbosity '"low"'
    toml_set "$edited" '' model_reasoning_summary '"concise"'
    # Edit and run commands in the workspace, with network access, and ask before anything
    # else. The desktop app uses these only while its permission picker is on Custom
    # (config.toml); its Ask for approval preset turns network access off.
    toml_set "$edited" '' approval_policy '"on-request"'
    toml_set "$edited" '' sandbox_mode '"workspace-write"'
    toml_set "$edited" sandbox_workspace_write network_access 'true'
    # Send OpenAI less: no usage metrics or product events (CLI and desktop app), and no
    # /feedback log uploads. Training on your chats is an account setting (see
    # open_manual_steps).
    toml_set "$edited" analytics enabled 'false'
    toml_set "$edited" feedback enabled 'false'

    # Desktop app: Settings → Git → Pull request merge method → Squash
    toml_set "$edited" desktop git-pull-request-merge-method '"squash"'
    # Desktop app: don't refresh worktrees from their upstream branch
    toml_set "$edited" desktop worktree-upstream-refresh-mode '"never"'
    # Desktop app: Settings → Notifications
    toml_set "$edited" desktop notifications-turn-mode '"unfocused"'
    toml_set "$edited" desktop notifications-permissions-enabled 'true'
    toml_set "$edited" desktop notifications-questions-enabled 'true'
    # Desktop app: Settings → General → Prevent sleep while running
    toml_set "$edited" desktop preventSleepWhileRunning 'true'
    # Desktop app: Settings → General → Show in menu bar (keeps ChatGPT in the menu bar, and
    # running, after the main window is closed)
    toml_set "$edited" desktop mac-menu-bar-enabled 'false'
    # Desktop app: Settings → Connections → Keep this Mac awake (plugged in, remote access on)
    toml_set "$edited" desktop keepRemoteControlAwakeWhilePluggedIn 'true'
    # Desktop app: a message sent mid-turn steers the running turn instead of queueing, and
    # threads show steps and commands
    toml_set "$edited" desktop followUpQueueMode '"steer"'
    toml_set "$edited" desktop conversationDetailMode '"STEPS_COMMANDS"'
    # Desktop app: show context window usage and ambient suggestions
    toml_set "$edited" desktop show-context-window-usage 'true'
    toml_set "$edited" desktop ambient-suggestions-enabled 'true'
    # Desktop app: open links and local URLs in your browser, not the built-in one
    toml_set "$edited" desktop open-link-in-target-preference '"external-browser"'
    toml_set "$edited" desktop open-local-url-in-target-preference '"external-browser"'
    # Desktop app: offer every reasoning effort in the picker
    toml_set "$edited" desktop enabled-reasoning-efforts \
        '["low", "medium", "high", "xhigh", "ultra", "persistent", "max"]'

    # Fail loudly if the result isn't valid TOML, leaving the original untouched
    if ! yq -p toml -o json '.' "$edited" > /dev/null; then
        echo "  $CODEX_CONFIG would not be valid TOML after editing; leaving it unchanged" >&2
        rm -f "$edited"
        return 1
    fi
    echo "$edited"
}

configure_codex() {
    echo "Configuring Codex..."
    local edited
    edited="$(codex_config_edited)" || return 1
    # Compare parsed TOML, so formatting the app rewrote doesn't count as a change
    if [ -f "$CODEX_CONFIG" ] &&
        [ "$(yq -p toml -o json '.' "$CODEX_CONFIG" 2>/dev/null)" == "$(yq -p toml -o json '.' "$edited")" ]; then
        rm -f "$edited"
        echo "  Output, sandbox, approval, data-sharing, and desktop app settings are already set"
        echo "  in $CODEX_CONFIG"
        return 0
    fi
    rm -f "$edited"

    # The ChatGPT app writes to config.toml too, so quit it before editing, then re-apply the
    # settings to whatever it wrote on the way out
    ensure_app_quit "ChatGPT" || return 0
    edited="$(codex_config_edited)" || return 1
    maybe_backup "$CODEX_CONFIG"
    mkdir -p "$(dirname "$CODEX_CONFIG")"
    mv "$edited" "$CODEX_CONFIG"
    echo "  Set output, sandbox, approval, data-sharing, and desktop app settings in $CODEX_CONFIG"
}

# ─── T3 Code desktop app ───

configure_t3_code() {
    echo "Configuring T3 Code..."
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
    if [ ! -d "/Applications/$T3_CODE_APP.app" ]; then
        echo "  $T3_CODE_APP isn't installed; skipping open at login"
    elif ! login_items="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)"; then
        echo "  Couldn't read Login Items; skipping. Allow the terminal to control System Events in"
        echo "  System Settings → Privacy & Security → Automation, or add $T3_CODE_APP in"
        echo "  System Settings → General → Login Items."
    elif [[ ", $login_items, " == *", $T3_CODE_APP, "* ]]; then
        echo "  Already opens at login"
    elif osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"/Applications/$T3_CODE_APP.app\", hidden:false}" > /dev/null; then
        echo "  Set to open at login"
    else
        echo "  Couldn't add $T3_CODE_APP to Login Items; add it in System Settings → General → Login Items."
    fi

    # Server settings (Settings → General, Threads, Storage): new threads use Claude Opus 5.5 in
    # auto mode, each in its own worktree; Add project starts in ~/Dev; threads continue after
    # an app update; inactive threads settle after 5 days; old worktrees, browser artifacts, and
    # logs are cleaned up; Cursor, Grok, and OpenCode are off.
    local settings='
        .defaultModelSelection = {"instanceId": "claudeAgent", "model": "claude-opus-5-5"}
        | .defaultRuntimeMode = "auto"
        | .defaultThreadEnvMode = "worktree"
        | .addProjectBaseDirectory = "~/Dev"
        | .continueThreadsAfterServerUpdate = true
        | .sidebarAutoSettleAfterDays = 5
        | .storageCleanup.worktreeAfterDays = 10
        | .storageCleanup.worktreeOnMerge = true
        | .storageCleanup.worktreeOnDelete = true
        | .storageCleanup.worktreeUnchanged = true
        | .storageCleanup.browserArtifactsAfterDays = 30
        | .storageCleanup.logsAfterDays = 30
        | .providers.cursor.enabled = false
        | .providers.grok.enabled = false
        | .providers.opencode.enabled = false
    '
    # Desktop settings: system notifications with sound and in-app notifications, a message
    # sent mid-turn steers the running turn instead of queueing, and diffs open expanded
    local client_settings='
        .notificationMode = "notifications-and-sound"
        | .inAppNotificationsEnabled = true
        | .followUpBehavior = "steer"
        | .diffFilesCollapsed = false
    '
    if json_applied "$T3_CODE_SETTINGS" "$settings" &&
        json_applied "$T3_CODE_CLIENT_SETTINGS" "$client_settings"; then
        echo "  Model, thread, cleanup, provider, and notification settings are already set"
        return 0
    fi
    ensure_app_quit "$T3_CODE_APP" || return 0
    json_merge "$T3_CODE_SETTINGS" "$settings"
    json_merge "$T3_CODE_CLIENT_SETTINGS" "$client_settings"
    echo "  Set model, thread, cleanup, provider, and notification settings"
}

# ─── User-level instructions (Claude Code + Codex) ───

install_user_instructions() {
    echo "Installing user-level instructions..."
    local src="$DOTFILES_DIR/ai_tools/user-instructions.md" dest
    for dest in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md"; do
        if cmp -s "$src" "$dest"; then
            echo "  $dest is already up to date"
            continue
        fi
        # The file may hold instructions added by hand, so only replace it when asked
        if [ -s "$dest" ] && ! confirm "  $dest differs from ai_tools/user-instructions.md. Replace it?"; then
            echo "  Left $dest unchanged. Merge ai_tools/user-instructions.md into it by hand."
            continue
        fi
        maybe_backup "$dest"
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo "  Copied ai_tools/user-instructions.md to $dest"
    done
}

# ─── Skills (Claude Code + Codex) ───

install_skills() {
    echo "Installing skills..."
    if ! command -v npx &>/dev/null; then
        echo "  npx not found; skipping. Install Node.js (e.g. with mise) and re-run."
        return 0
    fi
    # The skills CLI (https://skills.sh) copies the skills into ~/.agents/skills (Codex) and
    # symlinks them into ~/.claude/skills (Claude Code). Re-run after changing a skill.
    npx -y skills@latest add "$DOTFILES_DIR/ai_tools/skills" \
        --global --agent claude-code codex --skill '*' --yes
}

# ─── Things only you can do ───

# Succeeds when an app's notifications are allowed with the Persistent alert style. Fails when
# they aren't, or when the settings can't be read: macOS only lets a terminal with Full Disk
# Access read them. Flag bits as decoded by https://github.com/drewdiver/ncprefs.py:
# 1<<25 Allow notifications, 1<<3 Temporary (banners), 1<<4 Persistent (alerts).
notifications_persistent() {
    local bundle_id="$1" count i flags
    count="$(plutil -extract apps raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || return 1
    for ((i = 0; i < count; i++)); do
        [ "$(plutil -extract "apps.$i.bundle-id" raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" == "$bundle_id" ] || continue
        flags="$(plutil -extract "apps.$i.flags" raw -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || return 1
        return $(( (flags >> 25 & 1) && (flags >> 4 & 1) && !(flags >> 3 & 1) ? 0 : 1 ))
    done
    return 1
}

open_manual_steps() {
    local bundle_id pending_notifications="" extension_installed=false open_extension=false targets=""
    for bundle_id in com.mitchellh.ghostty com.anthropic.claudefordesktop com.openai.codex com.t3tools.t3code; do
        notifications_persistent "$bundle_id" || pending_notifications+=" $bundle_id"
    done
    if compgen -G "$HOME/Library/Application Support/Google/Chrome/*/Extensions/$CLAUDE_CHROME_EXTENSION_ID" > /dev/null; then
        extension_installed=true
    elif [ -d "/Applications/Google Chrome.app" ]; then
        open_extension=true
    fi

    echo ""
    echo "Remaining manual steps (macOS doesn't let scripts change these):"
    if [ -n "$pending_notifications" ]; then
        echo "  1. System Settings → Notifications → Ghostty (and any other terminal you use), Claude,"
        echo "     ChatGPT, T3 Code: turn on Allow notifications and set the alert style to Persistent."
    else
        echo "  1. System Settings → Notifications: Ghostty, Claude, ChatGPT, and T3 Code are already"
        echo "     allowed and Persistent. Do the same for any other terminal you use."
    fi
    echo "  2. Claude in Chrome extension: install it and sign in (for claude --chrome)."
    echo "  3. ChatGPT app: Plugins → Computer Use, and Settings → Computer Use → Chrome."
    echo "  4. Claude Code: /mcp → computer-use → Enable (per project), /chrome → Enabled by default."
    echo "  5. Training opt-outs, which are account settings: turn off model improvement in"
    echo "     claude.ai → Settings → Privacy, Improve the model for everyone in ChatGPT → Settings →"
    echo "     Data controls, and Include environments in the Codex settings on chatgpt.com/codex."
    echo "  See ai_tools/README.md for details."

    if "$extension_installed"; then
        echo "  Claude in Chrome extension already installed."
    fi

    # Only offer to open what still needs doing
    [ -n "$pending_notifications" ] && targets="the notification settings"
    "$open_extension" && targets="${targets:+$targets and }the Chrome extension page"
    if [ -z "$targets" ] || ! confirm "Open $targets now?"; then
        return 0
    fi

    for bundle_id in $pending_notifications; do
        open "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=$bundle_id"
        read -r -p "  Set $bundle_id to Allow notifications + Persistent, then press Enter..." _
    done

    if "$open_extension"; then
        open -a "Google Chrome" "https://chromewebstore.google.com/detail/claude/$CLAUDE_CHROME_EXTENSION_ID"
    fi

    if [ -n "$pending_notifications" ]; then
        echo "  Test a notification from your terminal with: $DOTFILES_DIR/scripts/test-notification.sh"
    fi
}

main() {
    echo "=== AI tools setup ==="
    install_apps
    configure_claude_code
    configure_claude_desktop
    configure_codex
    configure_t3_code
    install_user_instructions
    install_skills
    open_manual_steps
    echo ""
    echo "=== AI tools setup complete! ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
