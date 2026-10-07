#!/bin/bash
set -euo pipefail

# Install Claude Code, configure ~/.claude/settings.json, copy the status line script to
# ~/.claude/statusline.sh, and copy the user-level instructions to ~/.claude/CLAUDE.md.

# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CLAUDE_CODE_SETTINGS="$HOME/.claude/settings.json"

install_claude_code() {
    # The native installer auto-updates, so prefer it over the claude-code cask
    if command -v claude &>/dev/null; then
        echo "  Claude Code already installed ($(claude --version))."
    else
        echo "  Installing Claude Code..."
        curl -fsSL https://claude.ai/install.sh | bash
    fi
}

configure_claude_code() {
    echo "Configuring Claude Code..."
    # /config → Push when actions required, Push when Claude decides
    #   (mobile push notifications through the Claude app while Remote Control is active)
    # Start new sessions in auto mode. Only user or managed settings can make auto the default.
    # Turn off auto memory. Keep transcripts 90 days instead of 30, so /resume reaches further back.
    # Default to Opus 5.5 with medium effort, the fullscreen TUI, and normal key bindings.
    #   Switch models instead of pausing when safeguards flag a message. New worktrees branch
    #   from origin/<default-branch>.
    # Status line: ~/.claude/statusline.sh (model, effort, context, 5-hour limit, git branch).
    # Permission rules, which apply before auto mode's classifier: never read SSH or AWS
    #   credentials or .env files, always ask before pushing to main or master, and run test,
    #   typecheck, and lint commands without review. Rules are added to any already there.
    # Send Anthropic less: no error reports, session quality surveys (they can attach the
    #   transcript), /feedback, or feedback drafts. Training on your chats is an account
    #   setting (see ai_tools/manual-steps.sh). Telemetry stays on: DO_NOT_TRACK and
    #   DISABLE_TELEMETRY also stop Claude Code fetching feature flags, which turns off
    #   /advisor, /skill-doctor, skill and plugin sync, and more. Leave
    #   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC unset: it also turns off Remote Control, so
    #   mobile pushes stop.
    # shellcheck disable=SC2016 # jq variables, not shell ones
    local settings='
        def add($rules): (. // []) as $current | $current + ($rules - $current);

        .inputNeededNotifEnabled = true
        | .agentPushNotifEnabled = true
        | .permissions.defaultMode = "auto"
        | .permissions.deny |= add([
            "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(.env)", "Read(.env.*)"
          ])
        | .permissions.ask |= add([
            "Bash(git push * main)", "Bash(git push * main *)",
            "Bash(git push *:main)", "Bash(git push *:main *)",
            "Bash(git push * master)", "Bash(git push * master *)",
            "Bash(git push *:master)", "Bash(git push *:master *)"
          ])
        | .permissions.allow |= add([
            "Bash(go test *)", "Bash(go vet *)",
            "Bash(cargo test *)", "Bash(cargo check *)", "Bash(cargo clippy *)",
            "Bash(npm test *)", "Bash(npm run test *)", "Bash(npm run typecheck *)",
            "Bash(pnpm test *)", "Bash(pnpm run test *)", "Bash(pnpm typecheck *)",
            "Bash(pnpm run typecheck *)",
            "Bash(bun test *)", "Bash(bun run test *)", "Bash(bun run typecheck *)",
            "Bash(tsc --noEmit *)", "Bash(npx tsc --noEmit *)", "Bash(pnpm tsc --noEmit *)",
            "Bash(bunx tsc --noEmit *)",
            "Bash(pytest *)", "Bash(uv run pytest *)",
            "Bash(ruff check *)", "Bash(uv run ruff check *)"
          ])
        | .autoMemoryEnabled = false
        | .cleanupPeriodDays = 90
        | .model = "claude-opus-5-5"
        | .modelSettings["claude-opus-5-5"].effortLevel = "medium"
        | .modelSettings["claude-sonnet-5-5"].effortLevel = "high"
        | .tui = "fullscreen"
        | .editorMode = "normal"
        | .switchModelsOnFlag = true
        | .worktree.baseRef = "fresh"
        | .statusLine = {"type": "command", "command": "~/.claude/statusline.sh"}
        | .feedbackDrafts = "off"
        | .env.DISABLE_ERROR_REPORTING = "1"
        | .env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1"
        | .env.DISABLE_FEEDBACK_COMMAND = "1"
    '
    if json_applied "$CLAUDE_CODE_SETTINGS" "$settings"; then
        echo "  Push notifications, auto mode, permission rules, no auto memory, transcript retention,"
        echo "  model, TUI, worktree, status line, and data-sharing settings are already set"
        return 0
    fi
    json_merge "$CLAUDE_CODE_SETTINGS" "$settings"
    echo "  Turned on push notifications and auto mode by default, added permission rules, turned off"
    echo "  auto memory, kept transcripts 90 days, set the model, TUI, worktree, and status line"
    echo "  settings, and opted out of error reports, surveys, and feedback"
}

install_statusline() {
    echo "  Status line script:"
    copy_file "$DOTFILES_DIR/ai_tools/claude-code/statusline.sh" "$1"
    chmod 755 "$1"
}

# The file may hold instructions added by hand, so copy_file_ask only replaces it when asked
install_user_instructions() {
    echo "  User-level instructions:"
    copy_file_ask "$DOTFILES_DIR/ai_tools/user-instructions.md" "$1"
}

main() {
    echo "Setting up Claude Code..."
    install_claude_code
    configure_claude_code
    install_statusline "$HOME/.claude/statusline.sh"
    install_user_instructions "$HOME/.claude/CLAUDE.md"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
