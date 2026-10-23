#!/bin/bash
# shellcheck disable=SC2329

# The claude-desktop step: the app from its cask (macOS) or Anthropic's apt repo (Ubuntu), opened at
# login, and its settings merged into the app's config, keeping yours.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/claude-desktop/install.sh
# The test may run inside the Claude app, which ensure_app_quit handles on its own
replace_fn running_inside 'false'
# Keep the real /Applications/Claude.app out of the cask checks
APP="$HOME/Applications/Claude.app"
replace_fn cask_app_path 'echo "$APP"'
wrap_fn cask_state 'real_cask_state "$1" "$APP"'
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

# Ubuntu: Anthropic's apt repo, Claude's own autostart file, and the settings without the Mac's
ubuntu_step() {
    local config="$HOME/.config/Claude/claude_desktop_config.json"
    as_os ubuntu
    # The real check finds gnome-shell only on a desktop, which CI runners aren't
    replace_fn has_gnome_desktop 'true'
    assert_eq "$config" "$(claude_desktop_config)" "config path on Ubuntu"
    stub_apt_packages
    stub pgrep 'exit 1'
    stub_sudo_exec
    # shellcheck disable=SC2034 # the step reads it
    CLAUDE_APT_SOURCES="$SANDBOX/sources.list.d/claude-desktop.list"
    replace_fn apt_repo_published 'return 0'
    replace_fn add_apt_repo 'echo "add_apt_repo $1" >> "$STUB_LOG"; mkdir -p "${2%/*}"; printf "%s\n" "$3" > "$2"'
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Claude desktop app from Anthropic's apt repo"
    assert_contains "$RUN_OUTPUT" "missing    ~/.config/autostart/claude-desktop.desktop"
    cp "$STUB_LOG" "$SANDBOX/both.log"

    answer no
    assert_exit 0 main
    cat "$STUB_LOG" >> "$SANDBOX/both.log"
    assert_file_not_contains "$SANDBOX/both.log" "add_apt_repo"
    answer yes
    assert_exit 0 main
    assert_file_contains "$STUB_LOG" "add_apt_repo Claude"
    assert_file_contains "$STUB_LOG" "install -y claude-desktop"
    assert_eq 'false 30 null null' "$(jq -r '[.preferences.menuBarEnabled, .preferences.ccAutoArchiveInactiveDays,
        .preferences.dockBounceEnabled, .preferences.quickEntryShortcut] | map(tostring) | join(" ")' "$config")" \
        "Ubuntu's settings, without the Dock's or quick entry's"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         Claude desktop app from Anthropic's apt repo"

    # A second run changes nothing; a running Claude can't have its settings changed
    assert_exit 0 main
    assert_file_not_contains "$STUB_LOG" "apt-get"
    jq_edit "$config" '.preferences.menuBarEnabled = true'
    snapshot "$config"
    stub pgrep '[ "${*: -1}" == "^claude-desktop$" ] || [ "${*: -1}" == claude-desktop ]'
    assert_exit 0 main
    assert_unchanged "$config" "while Claude runs"

    # Ubuntu Server has no desktop to run it
    replace_fn has_gnome_desktop 'false'
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "skipped    Claude desktop app: no GNOME desktop"
    assert_exit 0 main
    assert_eq "" "$(cat "$STUB_LOG")" "commands run without a desktop"
}
subtest ubuntu_step

as_os macos
assert_eq "$CONFIG" "$(claude_desktop_config)" "config path"
stub brew '[ "$*" == "install --cask claude" ]'
stub pgrep 'exit 1'
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    claude (cask)"
assert_contains "$RUN_OUTPUT" "missing    ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "brew install --cask claude"

stub brew '[ "$*" == "list --cask claude" ]'
stub pgrep 'exit 1'
mkdir -p "$APP" "$(dirname "$CONFIG")"
echo '{"mcpServers": {"x": {"command": "y"}}, "preferences": {"sidebarMode": "chat", "menuBarEnabled": true, "quickEntryShortcut": {"enabled": true}}}' > "$CONFIG"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Claude desktop app settings"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "brew install"
assert_eq 'y chat false Alt+Space true' "$(jq -r '[.mcpServers.x.command, .preferences.sidebarMode,
    .preferences.menuBarEnabled, .preferences.quickEntryShortcut.accelerator,
    .preferences.quickEntryShortcut.enabled] | map(tostring) | join(" ")' "$CONFIG")" "merged settings"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Claude desktop app settings"
assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"

# Nothing to change, so a running Claude doesn't matter
before="$(/bin/ls -i "$CONFIG")"
stub pgrep 'exit 0'
assert_exit 0 main
assert_eq "$before" "$(/bin/ls -i "$CONFIG")" "config after a re-run"

stub pgrep 'exit 1'
for value in true '"Alt+Space"'; do
    jq_edit "$CONFIG" --argjson v "$value" '.preferences.quickEntryShortcut = $v'
    assert_exit 0 main
    assert_eq '{"accelerator":"Alt+Space"}' "$(jq -c .preferences.quickEntryShortcut "$CONFIG")" \
        "quick entry shortcut replacing $value"
done
test_done
