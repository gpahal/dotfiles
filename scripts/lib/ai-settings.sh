# A temp HOME and Claude Code's settings for the AI settings checks. Source it; don't run it.
# shellcheck shell=bash

# Fake git-wt so the claude-code step adds its worktree hooks. Source the steps after this; they read HOME on load.
temp_tool_home() {
    local var
    export HOME="$1"
    unset CLAUDE_CONFIG_DIR CODEX_HOME
    for var in $(compgen -v XDG_); do unset "$var"; done
    mkdir -p "$HOME/.local/bin" "$HOME/.claude" "$HOME/.codex"
    printf '#!/bin/sh\n' > "$HOME/.local/bin/git-wt"
    chmod +x "$HOME/.local/bin/git-wt"
}

write_claude_settings() {
    echo '{}' > "$CLAUDE_CODE_SETTINGS"
    json_merge "$CLAUDE_CODE_SETTINGS" "$(claude_code_settings)" > /dev/null
}
