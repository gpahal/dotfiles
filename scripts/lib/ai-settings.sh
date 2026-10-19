# shellcheck shell=bash
# The temp HOME that scripts/check-claude-keys.sh and scripts/check-ai-settings.sh write the AI
# tools' settings in, with the steps' own functions. It only defines functions.

# Point HOME at dir $1, so nothing reads or writes the real ~/.claude or ~/.codex, and unset what
# would send the steps elsewhere. A fake git wt is installed, since the claude-code step adds its
# worktree hooks only then. Source the steps after it, since they read HOME as they load.
# e.g. temp_tool_home "$tmp/macos"
temp_tool_home() {
    local var
    export HOME="$1"
    unset CLAUDE_CONFIG_DIR CODEX_HOME
    for var in $(compgen -v XDG_); do unset "$var"; done
    mkdir -p "$HOME/.local/bin" "$HOME/.claude" "$HOME/.codex"
    printf '#!/bin/sh\n' > "$HOME/.local/bin/git-wt"
    chmod +x "$HOME/.local/bin/git-wt"
}

# Write the settings the claude-code step writes over an empty settings file. Needs the step's
# functions loaded.
write_claude_settings() {
    echo '{}' > "$CLAUDE_CODE_SETTINGS"
    json_merge "$CLAUDE_CODE_SETTINGS" "$(claude_code_settings)" > /dev/null
}
