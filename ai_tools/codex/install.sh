#!/bin/bash
set -euo pipefail

# Install the Codex CLI and the ChatGPT desktop app, configure ~/.codex/config.toml (shared by
# both), and copy the user-level instructions to ~/.codex/AGENTS.md. The ChatGPT app writes to
# config.toml too, so it must be quit first; when run interactively the script offers to quit
# it, otherwise it skips the settings.

# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CODEX_CONFIG="$HOME/.codex/config.toml"

# Write a copy of the Codex config with the settings applied, and print its path
codex_config_edited() {
    local edited
    edited="$(mktemp)"
    [ -f "$CODEX_CONFIG" ] && cp "$CODEX_CONFIG" "$edited"

    # Default model, with high reasoning effort on the standard (not fast) service tier
    toml_set "$edited" '' model '"gpt-6.1-sol"'
    toml_set "$edited" '' model_reasoning_effort '"high"'
    toml_set "$edited" '' service_tier '"default"'
    # Short answers and reasoning summaries
    toml_set "$edited" '' model_verbosity '"low"'
    toml_set "$edited" '' model_reasoning_summary '"concise"'
    # Edit and run commands in the workspace without network access. Anything else, including
    # network access, goes to the auto-review agent instead of asking you. The desktop app uses
    # these only while its permission picker is on Custom (config.toml).
    toml_set "$edited" '' approval_policy '"on-request"'
    toml_set "$edited" '' approvals_reviewer '"auto_review"'
    toml_set "$edited" '' sandbox_mode '"workspace-write"'
    toml_set "$edited" sandbox_workspace_write network_access 'false'
    # Send OpenAI less: no usage metrics or product events (CLI and desktop app), and no
    # /feedback log uploads. Training on your chats is an account setting (see
    # ai_tools/manual-steps.sh).
    toml_set "$edited" analytics enabled 'false'
    toml_set "$edited" feedback enabled 'false'
    # CLI footer: model with reasoning effort, directory, git branch, and context used. /statusline
    # lists every item ID.
    toml_set "$edited" tui status_line '["model-with-reasoning", "current-dir", "git-branch", "context-used"]'

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
        echo "  Model, output, sandbox, approval, data-sharing, status line, and desktop app settings are"
        echo "  already set in $CODEX_CONFIG"
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
    echo "  Set model, output, sandbox, approval, data-sharing, status line, and desktop app settings in"
    echo "  $CODEX_CONFIG"
}

# The file may hold instructions added by hand, so copy_file_ask only replaces it when asked
install_user_instructions() {
    echo "  User-level instructions:"
    copy_file_ask "$DOTFILES_DIR/ai_tools/user-instructions.md" "$1"
}

main() {
    echo "Setting up Codex..."
    install_cask chatgpt /Applications/ChatGPT.app
    install_cask codex "$(brew --prefix)/bin/codex"
    configure_codex
    install_user_instructions "$HOME/.codex/AGENTS.md"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
