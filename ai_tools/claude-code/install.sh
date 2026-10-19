#!/bin/bash
set -euo pipefail

# Install Claude Code and set its settings, status line, worktree hook, and instructions.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../lib/keepable.sh
source "$DOTFILES_DIR/ai_tools/lib/keepable.sh"
# shellcheck source=../lib/tool-home.sh
source "$DOTFILES_DIR/ai_tools/lib/tool-home.sh"
# shellcheck source=../lib/user-instructions.sh
source "$DOTFILES_DIR/ai_tools/lib/user-instructions.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

CLAUDE_CODE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_CODE_STATUSLINE="$HOME/.claude/statusline.sh"
CLAUDE_CODE_WORKTREE_HOOK="$HOME/.claude/hooks/worktree-hook.sh"
CLAUDE_CODE_INSTRUCTIONS="$HOME/.claude/CLAUDE.md"
# Registered without git wt, every `claude -w` and isolated subagent would fail.
CLAUDE_CODE_NO_GIT_WT="git wt isn't installed, so the step didn't register the worktree hook. Run bash setup.sh git, then re-run this step."

# Usage: claude_code_keepable <jq path> <JSON value> <name> [ubuntu]
claude_code_keepable() {
    keepable claude_code "$1" "$2" "Claude Code's $3" "${4:-}"
}
keepable_forget claude_code
claude_code_keepable .model '"claude-opus-5-5"' "model (model)"
claude_code_keepable '.modelSettings["claude-opus-5-5"].effortLevel' '"medium"' \
    "claude-opus-5-5 effort (modelSettings.claude-opus-5-5.effortLevel)"
claude_code_keepable '.modelSettings["claude-sonnet-5-5"].effortLevel' '"high"' \
    "claude-sonnet-5-5 effort (modelSettings.claude-sonnet-5-5.effortLevel)"
claude_code_keepable .statusLine.type '"command"' "status line type (statusLine.type)"
claude_code_keepable .statusLine.command '"~/.claude/statusline.sh"' "status line command (statusLine.command)"
claude_code_keepable .statusLine.refreshInterval 5 \
    "status line refresh interval (statusLine.refreshInterval)"
# Over SSH, `auto` notifies nothing when TERM_PROGRAM didn't reach the tmux pane; ghostty's
# OSC 777 reaches the Mac either way.
claude_code_keepable .preferredNotifChannel '"ghostty"' "notification channel (preferredNotifChannel)" ubuntu

claude_code_keep_current() {
    jq -cr "$1 // empty" "$CLAUDE_CODE_SETTINGS" 2>/dev/null || true
}

claude_code_have_git_wt() {
    [ -x "$HOME/.local/bin/git-wt" ]
}

# shellcheck disable=SC2088 # Claude Code expands the ~
CLAUDE_CODE_WORKTREE_HOOK_COMMAND="~/.claude/hooks/worktree-hook.sh"

# Print "<event> already runs <command>" per foreign WorktreeCreate/WorktreeRemove hook. Claude
# Code runs them all and each create hook makes its own worktree, so ours must then be removed.
claude_code_other_worktree_hooks() {
    jq -r --arg ours "$CLAUDE_CODE_WORKTREE_HOOK_COMMAND" '
        (.hooks // {}) | objects | to_entries[]
        | select(.key == "WorktreeCreate" or .key == "WorktreeRemove")
        | .key as $event | .value[]?.hooks[]?
        | select(.command != $ours)
        | "\($event) already runs \(.command // .type // "a hook")"
    ' "$CLAUDE_CODE_SETTINGS" 2>/dev/null || true
}

# ~/.local/bin may not be on PATH yet after the native installer.
claude_code_path() {
    if command -v claude; then
        return 0
    fi
    [ -x "$HOME/.local/bin/claude" ] && echo "$HOME/.local/bin/claude"
}

# Print true, false, or nothing when unknown. auth status exits 1 when logged out.
claude_code_signed_in() {
    "$1" auth status --json 2>/dev/null |
        jq -r 'if .loggedIn == true or .loggedIn == false then .loggedIn else empty end' 2>/dev/null || true
}

install_claude_code() {
    # The native installer auto-updates; the cask doesn't
    local claude
    claude="$(claude_code_path)" || true
    if [ -n "$claude" ]; then
        echo "  Claude Code already installed ($("$claude" --version))."
    else
        echo "  Installing Claude Code..."
        run_installer bash https://claude.ai/install.sh "the Claude Code installer" || return 1
        if ! claude_code_path > /dev/null; then
            echo "  The Claude Code installer finished, but there's no claude on PATH or in ~/.local/bin." >&2
            return 1
        fi
    fi
}

# Usage: claude_code_settings [<register the worktree hook: true|false>]
claude_code_settings() {
    local register_hook="${1:-true}"
    # remoteControlAtStartup off: a connected session takes prompts from claude.ai and the phone.
    # Surveys off: they can attach the transcript. Telemetry stays on: DO_NOT_TRACK and
    # DISABLE_TELEMETRY also stop feature flags (/advisor, skill sync), and
    # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC stops Remote Control and so mobile pushes.
    local i op keepable=""
    for i in $(keepable_indexes claude_code); do
        op="//="
        if "${KEEP_REPLACE[i]}"; then op="="; fi
        keepable+="| ${KEEP_PATHS[i]} $op ${KEEP_VALUES[i]}"
    done
    # shellcheck disable=SC2016 # jq variables, not shell ones
    local settings='
        # Resets the timeout, since a hand-edited short one would kill the hook mid-fetch
        def add_hook($command; $timeout):
            (. // []) as $groups
            | if any($groups[].hooks[]?; .command == $command) then
                $groups | map(if (.hooks | type) == "array" then
                        .hooks |= map(if .command == $command then .type = "command" | .timeout = $timeout else . end)
                    else . end)
              else $groups + [{"hooks": [{"type": "command", "command": $command, "timeout": $timeout}]}] end;
        def remove_hook($event; $command):
            if (.hooks | type) == "object" and (.hooks[$event] | type) == "array" then
                .hooks[$event] |= map(if (.hooks | type) == "array" then
                        .hooks |= map(select(.command != $command))
                        | select(.hooks != [])
                    else . end)
                | if .hooks[$event] == [] then del(.hooks[$event]) else . end
            else . end;

        .inputNeededNotifEnabled = true
        | .agentPushNotifEnabled = true
        | .remoteControlAtStartup = false
        | .permissions.defaultMode = "auto"
        | .autoMemoryEnabled = false
        | .cleanupPeriodDays = 90
        '"$keepable"'
        | .tui = "fullscreen"
        | .editorMode = "normal"
        | .switchModelsOnFlag = true
        | .feedbackDrafts = "off"
        | .env.DISABLE_ERROR_REPORTING = "1"
        | .env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1"
        | .env.DISABLE_FEEDBACK_COMMAND = "1"
    '
    local hook="$CLAUDE_CODE_WORKTREE_HOOK_COMMAND"
    if [ -n "$(claude_code_other_worktree_hooks)" ] || ! "$register_hook" || ! claude_code_have_git_wt; then
        # An earlier run may have registered ours
        settings+='| remove_hook("WorktreeCreate"; "'"$hook"'")
            | remove_hook("WorktreeRemove"; "'"$hook"'")
            | remove_hook("SessionEnd"; "'"$hook"'")'
    else
        # 120 s stops a stuck git wt holding claude -w for the default 10 min. SessionEnd hooks
        # get 1.5 s unless one sets longer, and git wt prune checks each worktree.
        settings+='| .hooks.WorktreeCreate |= add_hook("'"$hook"'"; 120)
            | .hooks.WorktreeRemove |= add_hook("'"$hook"'"; 120)
            | .hooks.SessionEnd |= add_hook("'"$hook"'"; 30)'
    fi
    printf '%s\n' "$settings"
}

# Usage: configure_claude_code [<register the worktree hook: true|false>]
configure_claude_code() {
    echo "Configuring Claude Code..."
    local settings
    keepable_choose claude_code
    settings="$(claude_code_settings "${1:-true}")"
    if json_applied "$CLAUDE_CODE_SETTINGS" "$settings"; then
        echo "  Push notifications, Remote Control off, auto mode, no auto memory, transcript retention,"
        echo "  model, TUI, worktree, status line, and data-sharing settings are already set"
        return 0
    fi
    json_merge "$CLAUDE_CODE_SETTINGS" "$settings" || return 1
    echo "  Turned on push notifications and auto mode by default, turned off Remote Control at startup"
    echo "  and auto memory, kept transcripts 90 days, set the model, TUI, worktree, and status line settings,"
    echo "  and opted out of error reports, surveys, and feedback"
}

script_files() {
    local status=0
    "$1" "$DOTFILES_DIR/ai_tools/claude-code/statusline.sh" "$CLAUDE_CODE_STATUSLINE" || status=1
    "$1" "$DOTFILES_DIR/ai_tools/claude-code/worktree-hook.sh" "$CLAUDE_CODE_WORKTREE_HOOK" || status=1
    return "$status"
}

user_instructions_files() {
    user_instructions_to "$CLAUDE_CODE_INSTRUCTIONS" "$@"
}

install_scripts() {
    echo "  Status line script and worktree hook:"
    script_files copy_file
}

status() {
    local line claude
    if claude="$(claude_code_path)"; then
        status_item ok "Claude Code"
        if status_require_cmd jq "Signed in to Claude Code"; then
            case "$(claude_code_signed_in "$claude")" in
                true) status_item ok "Signed in to Claude Code" ;;
                false) status_item missing "Signed in to Claude Code: run claude auth login" ;;
                *) status_item unknown "Signed in to Claude Code: claude auth status didn't say; run it to see why" ;;
            esac
        fi
    else
        status_item missing "Claude Code"
        status_item unknown "Signed in to Claude Code: Claude Code isn't installed"
    fi
    if ! tool_home_guard --status "Claude Code settings, status line, and instructions" \
        "Claude Code" CLAUDE_CONFIG_DIR "$HOME/.claude"; then
        status_result
        return
    fi
    if status_require_cmd jq "Settings in ~/.claude/settings.json"; then
        status_check "Settings in ~/.claude/settings.json" json_applied "$CLAUDE_CODE_SETTINGS" "$(claude_code_settings)"
        keepable_status claude_code
    fi
    claude_code_have_git_wt || status_item missing "Worktree hook: $CLAUDE_CODE_NO_GIT_WT"
    while IFS= read -r line; do
        [ -z "$line" ] || status_item missing "Worktree hook: $line, so ours isn't registered; remove it from ~/.claude/settings.json and re-run the step"
    done <<< "$(claude_code_other_worktree_hooks)"
    script_files status_file
    user_instructions_files status_file
    status_result
}

apply() {
    echo "Claude Code:"
    tool_home_guard "Claude Code" CLAUDE_CONFIG_DIR "$HOME/.claude" || return 1
    require_cmd jq || return 1
    if ! claude_code_path > /dev/null; then
        require_cmd curl || return 1
    fi
    local status=0
    install_claude_code || status=1
    # Register the hook only if its copy is executable; otherwise worktree creation would fail.
    install_scripts || status=1
    local register_hook=true
    [ -x "$CLAUDE_CODE_WORKTREE_HOOK" ] || register_hook=false
    configure_claude_code "$register_hook" || status=1
    install_user_instructions "$CLAUDE_CODE_INSTRUCTIONS" || status=1
    if ! claude_code_have_git_wt; then
        echo "  $CLAUDE_CODE_NO_GIT_WT" >&2
        return 1
    fi
    local others line
    others="$(claude_code_other_worktree_hooks)"
    if [ -n "$others" ]; then
        while IFS= read -r line; do
            echo "  $line, so the step didn't register the worktree hook: Claude Code would run both," >&2
        done <<< "$others"
        echo "  and each create hook makes its own worktree. Remove the other hook from" >&2
        echo "  ~/.claude/settings.json, then re-run this step." >&2
        return 1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
