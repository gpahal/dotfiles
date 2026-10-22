#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail


# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/claude-desktop/install.sh
# The test may run inside the Claude app, which ensure_app_quit handles on its own
replace_fn running_inside 'false'
# Keep the real /Applications/Claude.app out of the cask checks
APP="$HOME/Applications/Claude.app"
replace_fn cask_app_path 'echo "$APP"'
wrap_fn cask_state 'real_cask_state "$1" "$APP"'
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
AGENT="$HOME/Library/LaunchAgents/dotfiles.claude-desktop.plist"

# GNOME starts the app and its autostart without a shell's XDG_CONFIG_HOME
xdg_config_home() {
    export XDG_CONFIG_HOME="$SANDBOX/xdg"
    load_script ai_tools/claude-desktop/install.sh
    assert_eq "$HOME/.config/Claude/claude_desktop_config.json" "$CLAUDE_DESKTOP_UBUNTU_CONFIG" \
        "config path with XDG_CONFIG_HOME set"
    assert_eq "$HOME/.config/autostart/claude-desktop.desktop" "$CLAUDE_DESKTOP_AUTOSTART" \
        "autostart path with XDG_CONFIG_HOME set"
}
subtest xdg_config_home

# Ubuntu: Anthropic's apt repo, Claude's own autostart file, and the settings without the Mac's
ubuntu_step() {
    local config="$HOME/.config/Claude/claude_desktop_config.json"
    local autostart="$HOME/.config/autostart/claude-desktop.desktop"
    as_os ubuntu
    # The real check finds gnome-shell only on a desktop, which CI runners aren't
    replace_fn has_gnome_desktop 'true'
    assert_eq "$config" "$(claude_desktop_config)" "config path on Ubuntu"
    stub dpkg-query '[ "${*: -1}" == claude-desktop ] && [ -e "$SANDBOX/installed" ] && printf "install ok installed"'
    stub apt-get '[ "${*: -1}" != claude-desktop ] || touch "$SANDBOX/installed"'
    stub pgrep 'exit 1'
    stub_sudo_exec
    export SANDBOX
    CLAUDE_APT_SOURCES="$SANDBOX/sources.list.d/claude-desktop.list"
    replace_fn apt_repo_published 'return 0'
    replace_fn add_apt_repo 'echo "add_apt_repo $1 $2 $4 $5 $6" >> "$STUB_LOG"; mkdir -p "${2%/*}"; printf "%s\n" "$3" > "$2"'
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Claude desktop app from Anthropic's apt repo"
    assert_contains "$RUN_OUTPUT" "missing    ~/.config/autostart/claude-desktop.desktop"

    answer no
    assert_exit 0 main
    assert_file_not_contains "$STUB_LOG" "add_apt_repo"
    answer yes
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_file_contains "$STUB_LOG" "add_apt_repo Claude $CLAUDE_APT_SOURCES https://downloads.claude.ai/claude-desktop/key.asc /usr/share/keyrings/claude-desktop-archive-keyring.asc 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
    assert_file_contains "$STUB_LOG" "install -y claude-desktop"
    assert_file_contains "$CLAUDE_APT_SOURCES" "### Managed by the claude-desktop package."
    assert_eq '[Desktop Entry]
Type=Application
Name=Claude
Exec="/usr/lib/claude-desktop/claude-desktop" --startup
X-GNOME-Autostart-enabled=true' "$(cat "$autostart")" "the autostart file Claude's own setting writes"
    assert_eq 'false 30 null null' "$(jq -r '[.preferences.menuBarEnabled, .preferences.ccAutoArchiveInactiveDays,
        .preferences.dockBounceEnabled, .preferences.quickEntryShortcut] | map(tostring) | join(" ")' "$config")" \
        "Ubuntu's settings, without the Dock's or quick entry's"
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "ok         Claude desktop app from Anthropic's apt repo"

    # A second run changes nothing; a running Claude can't have its settings changed
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "claude-desktop is already installed from Anthropic's apt repo."
    assert_contains "$RUN_OUTPUT" "Keep-awake, archiving, tray icon, and Cowork settings are already set"
    assert_file_not_contains "$STUB_LOG" "apt-get"
    jq '.preferences.menuBarEnabled = true' "$config" > "$SANDBOX/changed.json"
    cp "$SANDBOX/changed.json" "$config"
    stub pgrep '[ "${*: -1}" == "^claude-desktop$" ] || [ "${*: -1}" == claude-desktop ]'
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "claude-desktop is running and must be quit to change its settings"
    assert_eq "$(cat "$SANDBOX/changed.json")" "$(cat "$config")" "config while Claude runs"

    # Ubuntu Server has no desktop to run it
    replace_fn has_gnome_desktop 'false'
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "skipped    Claude desktop app: no GNOME desktop"
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "No GNOME desktop, so no desktop app."
    assert_eq "" "$(cat "$STUB_LOG")" "commands run without a desktop"
}
subtest ubuntu_step

as_os macos
assert_eq "$CONFIG" "$(claude_desktop_config)" "config path"
stub brew '[ "$*" == "install --cask claude" ]'
stub pgrep 'exit 1'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    claude (cask)"
assert_contains "$RUN_OUTPUT" "missing    ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installing claude..."
assert_contains "$RUN_OUTPUT" "Copied ai_tools/claude-desktop/dotfiles.claude-desktop.plist to $AGENT"
assert_eq "$(cat "$DOTFILES_DIR/ai_tools/claude-desktop/dotfiles.claude-desktop.plist")" "$(cat "$AGENT")" "LaunchAgent"
assert_file_contains "$STUB_LOG" "brew install --cask claude"

stub brew '[ "$*" == "list --cask claude" ]'
stub pgrep 'exit 1'
mkdir -p "$APP" "$(dirname "$CONFIG")"
echo '{"mcpServers": {"x": {"command": "y"}}, "preferences": {"sidebarMode": "chat", "menuBarEnabled": true, "quickEntryShortcut": {"enabled": true}}}' > "$CONFIG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Claude desktop app settings"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "claude already installed."
assert_contains "$RUN_OUTPUT" "Set notifications, keep-awake"
assert_file_not_contains "$STUB_LOG" "brew install"
assert_eq 'y chat false Alt+Space true' "$(jq -r '[.mcpServers.x.command, .preferences.sidebarMode,
    .preferences.menuBarEnabled, .preferences.quickEntryShortcut.accelerator,
    .preferences.quickEntryShortcut.enabled] | map(tostring) | join(" ")' "$CONFIG")" "merged settings"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Claude desktop app settings"
assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"

# Nothing to change, so a running Claude doesn't matter
before="$(/bin/ls -i "$CONFIG")"
stub pgrep 'exit 0'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set"
assert_contains "$RUN_OUTPUT" "$AGENT is already up to date"
assert_eq "$before" "$(/bin/ls -i "$CONFIG")" "config after a re-run"

stub pgrep 'exit 1'
for value in true '"Alt+Space"'; do
    jq --argjson v "$value" '.preferences.quickEntryShortcut = $v' "$CONFIG" > "$SANDBOX/q.json"
    cp "$SANDBOX/q.json" "$CONFIG"
    assert_exit 0 main
    assert_eq '{"accelerator":"Alt+Space"}' "$(jq -c .preferences.quickEntryShortcut "$CONFIG")" \
        "quick entry shortcut replacing $value"
done
stub pgrep 'exit 0'

jq '.preferences.menuBarEnabled = true' "$CONFIG" > "$SANDBOX/changed.json"
cp "$SANDBOX/changed.json" "$CONFIG"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Claude is running; skipping."
assert_eq "$(cat "$SANDBOX/changed.json")" "$(cat "$CONFIG")" "config while Claude runs"
assert_file_not_contains "$STUB_LOG" "osascript"

no_jq_status() {
    hide jq
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "ok         claude (cask)"
    assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"
    assert_contains "$RUN_OUTPUT" "unknown    Claude desktop app settings: $(missing_cmd_hint jq)"
}
subtest no_jq_status
test_done
