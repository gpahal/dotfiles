#!/bin/bash
set -euo pipefail

# Set up AI tools:
#
# - Claude Code CLI
# - Claude desktop app
# - Codex CLI
# - ChatGPT desktop app
#
# Idempotent: safe to re-run. Apps whose config is edited (Claude, ChatGPT) must be quit
# first; when run interactively the script offers to quit them, otherwise it skips them.
#
# Things macOS doesn't allow scripts to change (notification alert style, Accessibility and
# Screen Recording permissions, installing browser extensions) are opened for you at the end.
# See AI_TOOLS_SETUP.md for the full checklist.

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

CLAUDE_CODE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
CLAUDE_CHROME_EXTENSION_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"

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

# Before editing an existing file, ask whether to back it up to <file>.bak
maybe_backup() {
    local prompt="  Back up $1 to $1.bak?"
    [ -f "$1" ] || return 0
    [ -f "$1.bak" ] && prompt="  Back up $1 to $1.bak (overwrites the existing $1.bak)?"
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
    json_merge "$CLAUDE_CODE_SETTINGS" '
        .inputNeededNotifEnabled = true
        | .agentPushNotifEnabled = true
    '
    echo "  Turned on Push when actions required and Push when Claude decides"
}

# ─── Claude desktop app ───

configure_claude_desktop() {
    echo "Configuring Claude desktop app..."
    ensure_app_quit "Claude" || return 0
    # Settings → Claude Code:
    #   Draw attention on notifications → On
    #   Archive inactive sessions → 30 days
    #   Keep computer awake while Claude works → On
    #   Keep awake on battery power → On
    json_merge "$CLAUDE_DESKTOP_CONFIG" '
        .preferences.dockBounceEnabled = true
        | .preferences.ccAutoArchiveInactiveDays = 30
        | .preferences.ccKeepAwakeWhileWorking = true
        | .preferences.ccKeepAwakeOnBattery = true
    '
    echo "  Turned on Draw attention on notifications and keep awake while working (also on battery),"
    echo "  and set Archive inactive sessions to 30 days"
}

# ─── Codex (ChatGPT desktop app + Codex CLI) ───

configure_codex() {
    echo "Configuring Codex..."
    # The ChatGPT app writes to config.toml too, so quit it before editing
    ensure_app_quit "ChatGPT" || return 0
    maybe_backup "$CODEX_CONFIG"
    local snapshot
    snapshot="$(mktemp)"
    [ -f "$CODEX_CONFIG" ] && cp "$CODEX_CONFIG" "$snapshot"

    # Desktop app: Settings → Git → Pull request merge method → Squash
    toml_set "$CODEX_CONFIG" desktop git-pull-request-merge-method '"squash"'
    # Desktop app: Settings → Notifications
    toml_set "$CODEX_CONFIG" desktop notifications-turn-mode '"unfocused"'
    toml_set "$CODEX_CONFIG" desktop notifications-permissions-enabled 'true'
    toml_set "$CODEX_CONFIG" desktop notifications-questions-enabled 'true'
    # Desktop app: Settings → General → Prevent sleep while running
    toml_set "$CODEX_CONFIG" desktop preventSleepWhileRunning 'true'
    # Desktop app: Settings → Connections → Keep this Mac awake (plugged in, remote access on)
    toml_set "$CODEX_CONFIG" desktop keepRemoteControlAwakeWhilePluggedIn 'true'

    # Fail loudly if the result isn't valid TOML
    if ! yq -p toml -o json '.' "$CODEX_CONFIG" > /dev/null; then
        echo "  $CODEX_CONFIG is not valid TOML after editing; restoring the original"
        cp "$snapshot" "$CODEX_CONFIG"
        return 1
    fi
    echo "  Set PR merge method to squash and turned on notifications and keep-awake in $CODEX_CONFIG"
}

# ─── Things only you can do ───

open_manual_steps() {
    echo ""
    echo "Remaining manual steps (macOS doesn't let scripts change these):"
    echo "  1. System Settings → Notifications → Ghostty (and any other terminal you use), Claude,"
    echo "     ChatGPT: turn on Allow notifications and set the alert style to Persistent."
    echo "  2. Claude in Chrome extension: install it and sign in (for claude --chrome)."
    echo "  3. ChatGPT app: Plugins → Computer Use, and Settings → Computer Use → Chrome."
    echo "  4. Claude Code: /mcp → computer-use → Enable (per project), /chrome → Enabled by default."
    echo "  See AI_TOOLS_SETUP.md for details."

    if ! confirm "Open the notification settings and the Chrome extension page now?"; then
        return 0
    fi

    local bundle_id
    for bundle_id in com.mitchellh.ghostty com.anthropic.claudefordesktop com.openai.codex; do
        open "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=$bundle_id"
        read -r -p "  Set $bundle_id to Allow notifications + Persistent, then press Enter..." _
    done

    if compgen -G "$HOME/Library/Application Support/Google/Chrome/*/Extensions/$CLAUDE_CHROME_EXTENSION_ID" > /dev/null; then
        echo "  Claude in Chrome extension already installed."
    elif [ -d "/Applications/Google Chrome.app" ]; then
        open -a "Google Chrome" "https://chromewebstore.google.com/detail/claude/$CLAUDE_CHROME_EXTENSION_ID"
    fi

    echo "  Test a notification from your terminal with: $DOTFILES_DIR/scripts/test-notification.sh"
}

main() {
    echo "=== AI tools setup ==="
    install_apps
    configure_claude_code
    configure_claude_desktop
    configure_codex
    open_manual_steps
    echo ""
    echo "=== AI tools setup complete! ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
