#!/bin/bash
set -euo pipefail

# Set up AI tools:
#
# - Claude Code CLI
# - Claude desktop app
# - Codex CLI
# - ChatGPT desktop app
# - Skills in ai_tools/skills, for Claude Code and Codex
#
# Idempotent: safe to re-run. Apps whose config is edited (Claude, ChatGPT) must be quit
# first; when run interactively the script offers to quit them, otherwise it skips them.
#
# Things macOS doesn't allow scripts to change (notification alert style, Accessibility and
# Screen Recording permissions, installing browser extensions) are opened for you at the end.
# See ai_tools/README.md for the full checklist.

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

CLAUDE_CODE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
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

# Quit a running app (after asking). Returns non-zero if it is still running.
ensure_app_quit() {
    local app="$1"
    pgrep -x "$app" &>/dev/null || return 0
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
# ordering) untouched. `value` must already be a TOML literal, e.g. '"squash"' or 'true'.
toml_set() {
    local file="$1" table="$2" key="$3" value="$4" tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp="$(mktemp)"
    awk -v table="[$table]" -v key="$key" -v value="$value" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function is_header(s) { return s ~ /^[ \t]*\[/ }
        function flush_blanks() { for (; blanks > 0; blanks--) print "" }
        {
            line = $0
            if (is_header(line)) {
                # Leaving the target table without finding the key: add it after its last entry
                if (in_table && !done) { print key " = " value; done = 1 }
                flush_blanks()
                in_table = (trim(line) == table)
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
            if (!seen_table) { print ""; print table; print key " = " value }
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
    # (mobile push notifications through the Claude app while Remote Control is active)
    local settings='
        .inputNeededNotifEnabled = true
        | .agentPushNotifEnabled = true
    '
    if json_applied "$CLAUDE_CODE_SETTINGS" "$settings"; then
        echo "  Push when actions required and Push when Claude decides are already on"
        return 0
    fi
    json_merge "$CLAUDE_CODE_SETTINGS" "$settings"
    echo "  Turned on Push when actions required and Push when Claude decides"
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
    local settings='
        .preferences.dockBounceEnabled = true
        | .preferences.ccAutoArchiveInactiveDays = 30
        | .preferences.ccKeepAwakeWhileWorking = true
        | .preferences.ccKeepAwakeOnBattery = true
        | .preferences.menuBarEnabled = false
    '
    if json_applied "$CLAUDE_DESKTOP_CONFIG" "$settings"; then
        echo "  Draw attention on notifications, keep awake while working (also on battery),"
        echo "  Archive inactive sessions after 30 days, and no menu bar icon are already set"
        return 0
    fi
    ensure_app_quit "Claude" || return 0
    json_merge "$CLAUDE_DESKTOP_CONFIG" "$settings"
    echo "  Turned off Show in menu bar, turned on Draw attention on notifications and keep awake"
    echo "  while working (also on battery), and set Archive inactive sessions to 30 days"
}

# ─── Codex (ChatGPT desktop app + Codex CLI) ───

# Write a copy of the Codex config with the settings applied, and print its path
codex_config_edited() {
    local edited
    edited="$(mktemp)"
    [ -f "$CODEX_CONFIG" ] && cp "$CODEX_CONFIG" "$edited"

    # Desktop app: Settings → Git → Pull request merge method → Squash
    toml_set "$edited" desktop git-pull-request-merge-method '"squash"'
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
        echo "  PR merge method, notifications, keep-awake, and no menu bar icon are already set"
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
    echo "  Set PR merge method to squash, turned on notifications and keep-awake, and turned off"
    echo "  Show in menu bar in $CODEX_CONFIG"
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
    for bundle_id in com.mitchellh.ghostty com.anthropic.claudefordesktop com.openai.codex; do
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
        echo "     ChatGPT: turn on Allow notifications and set the alert style to Persistent."
    else
        echo "  1. System Settings → Notifications: Ghostty, Claude, and ChatGPT are already allowed and"
        echo "     Persistent. Do the same for any other terminal you use."
    fi
    echo "  2. Claude in Chrome extension: install it and sign in (for claude --chrome)."
    echo "  3. ChatGPT app: Plugins → Computer Use, and Settings → Computer Use → Chrome."
    echo "  4. Claude Code: /mcp → computer-use → Enable (per project), /chrome → Enabled by default."
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
    install_skills
    open_manual_steps
    echo ""
    echo "=== AI tools setup complete! ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
