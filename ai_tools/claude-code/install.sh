#!/bin/bash
set -euo pipefail

# Install Claude Code, configure ~/.claude/settings.json, copy the status line script to
# ~/.claude/statusline.sh and the worktree hook to ~/.claude/hooks/worktree-hook.sh, and copy the
# user-level instructions to ~/.claude/CLAUDE.md.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CLAUDE_CODE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_CODE_STATUSLINE="$HOME/.claude/statusline.sh"
CLAUDE_CODE_WORKTREE_HOOK="$HOME/.claude/hooks/worktree-hook.sh"
CLAUDE_CODE_INSTRUCTIONS="$HOME/.claude/CLAUDE.md"
# The paths above and the docs all assume ~/.claude, so another CLAUDE_CONFIG_DIR fails the step
# rather than leaving Claude Code reading files setup never wrote
CLAUDE_CODE_HOME_POLICY="setup assumes Claude Code's default home (~/.claude); unset CLAUDE_CONFIG_DIR or move it"
# The worktree hook runs git wt, which the git step installs. Registered without it, every
# `claude -w` and isolated subagent would fail.
CLAUDE_CODE_NO_GIT_WT="git wt isn't installed, so the step didn't register the worktree hook. Run bash setup.sh git, then re-run this step."

# Values you can change, such as with /model or /effort: each is set only when unset, and one of
# your own is replaced only when replace_custom_value agrees. Each has a jq path, the repo's value
# as JSON, the name prompts and status give it, and whether it's set only on Ubuntu.
# configure_claude_code sets CLAUDE_CODE_REPLACE to whether to write each over yours.
CLAUDE_CODE_KEEP_PATHS=()
CLAUDE_CODE_KEEP_VALUES=()
CLAUDE_CODE_KEEP_NAMES=()
CLAUDE_CODE_KEEP_UBUNTU=()
CLAUDE_CODE_REPLACE=()
# Usage: claude_code_keepable <jq path> <JSON value> <name> [ubuntu]
claude_code_keepable() {
    CLAUDE_CODE_KEEP_PATHS+=("$1")
    CLAUDE_CODE_KEEP_VALUES+=("$2")
    CLAUDE_CODE_KEEP_NAMES+=("Claude Code's $3")
    CLAUDE_CODE_KEEP_UBUNTU+=("$([ "${4:-}" == ubuntu ] && echo true || echo false)")
    CLAUDE_CODE_REPLACE+=(false)
}
claude_code_keepable .model '"claude-opus-5-5"' "model (model)"
claude_code_keepable '.modelSettings["claude-opus-5-5"].effortLevel' '"medium"' \
    "claude-opus-5-5 effort (modelSettings.claude-opus-5-5.effortLevel)"
claude_code_keepable '.modelSettings["claude-sonnet-5-5"].effortLevel' '"high"' \
    "claude-sonnet-5-5 effort (modelSettings.claude-sonnet-5-5.effortLevel)"
claude_code_keepable .statusLine.type '"command"' "status line type (statusLine.type)"
claude_code_keepable .statusLine.command '"~/.claude/statusline.sh"' "status line command (statusLine.command)"
claude_code_keepable .statusLine.refreshInterval 5 \
    "status line refresh interval (statusLine.refreshInterval)"
# Ubuntu is used over SSH. The ubuntu step's AcceptEnv and zsh/hooks.zsh carry Ghostty's
# TERM_PROGRAM into tmux panes, but a session that didn't come through them (an older tmux
# server, or a client that sends no TERM_PROGRAM) leaves `auto` with no notification. Pin
# Ghostty's channel, which sends OSC 777, wrapped for tmux, back to the Mac.
claude_code_keepable .preferredNotifChannel '"ghostty"' "notification channel (preferredNotifChannel)" ubuntu

# Succeeds when value $1 of CLAUDE_CODE_KEEP_PATHS applies on this OS
claude_code_keep_applies() {
    ! "${CLAUDE_CODE_KEEP_UBUNTU[$1]}" || is_ubuntu
}

# Print the settings' value at jq path $1, or nothing when it's unset or the file can't be read
claude_code_value() {
    jq -cr "$1 // empty" "$CLAUDE_CODE_SETTINGS" 2>/dev/null || true
}

# Print the repo's value $1 of CLAUDE_CODE_KEEP_VALUES as claude_code_value prints it
claude_code_keep_wanted() {
    local value="${CLAUDE_CODE_KEEP_VALUES[$1]}"
    value="${value#\"}"
    printf '%s\n' "${value%\"}"
}

claude_code_have_git_wt() {
    [ -x "$HOME/.local/bin/git-wt" ]
}

# The command settings.json runs the worktree hook with
# shellcheck disable=SC2088 # Claude Code expands the ~
CLAUDE_CODE_WORKTREE_HOOK_COMMAND="~/.claude/hooks/worktree-hook.sh"

# Print "<event> already runs <command>" for each command other than ours in WorktreeCreate or
# WorktreeRemove. Claude Code runs every hook an event lists, and each create hook would make its
# own worktree, so while one prints anything the step takes ours out of both events.
claude_code_other_worktree_hooks() {
    jq -r --arg ours "$CLAUDE_CODE_WORKTREE_HOOK_COMMAND" '
        (.hooks // {}) | objects | to_entries[]
        | select(.key == "WorktreeCreate" or .key == "WorktreeRemove")
        | .key as $event | .value[]?.hooks[]?
        | select(.command != $ours)
        | "\($event) already runs \(.command // .type // "a hook")"
    ' "$CLAUDE_CODE_SETTINGS" 2>/dev/null || true
}

# Print the path of claude. The native installer puts it in ~/.local/bin, which may not be on this
# shell's PATH yet.
claude_code_path() {
    if command -v claude; then
        return 0
    fi
    [ -x "$HOME/.local/bin/claude" ] && echo "$HOME/.local/bin/claude"
}

# Print true or false for whether claude is signed in, or nothing when it can't tell. claude auth
# status prints loggedIn either way, and exits 1 when it's false.
claude_code_signed_in() {
    "$1" auth status --json 2>/dev/null |
        jq -r 'if .loggedIn == true or .loggedIn == false then .loggedIn else empty end' 2>/dev/null || true
}

install_claude_code() {
    # The native installer auto-updates, so prefer it over the claude-code cask
    local claude
    claude="$(claude_code_path)" || true
    if [ -n "$claude" ]; then
        echo "  Claude Code already installed ($("$claude" --version))."
    else
        echo "  Installing Claude Code..."
        run_installer bash https://claude.ai/install.sh "the Claude Code installer"
    fi
}

# Print the jq filter that applies the settings. With false, it removes our worktree hook instead of
# registering it: the copy isn't executable, so Claude Code would fail to create worktrees.
# Usage: claude_code_settings [<register the worktree hook: true|false>]
claude_code_settings() {
    local register_hook="${1:-true}"
    # /config → Push when actions required, Push when Claude decides
    #   (mobile push notifications through the Claude app while Remote Control is active). Enable
    #   Remote Control for all sessions stays off, since a connected session takes prompts from
    #   claude.ai and the phone app, so only a session /remote-control connects can push
    # Start new sessions in auto mode. Only user or managed settings can make auto the default.
    # Turn off auto memory. Keep transcripts 90 days instead of 30, so /resume reaches further back.
    # Default to Opus 5.5 with medium effort, the fullscreen TUI, and normal key bindings.
    #   Switch models instead of pausing when safeguards flag a message.
    # Worktrees: ~/.claude/hooks/worktree-hook.sh creates them, branching from origin's default
    #   branch, and removes them under ~/.worktrees/<group>/<repo>/<name>, through git wt, and at
    #   SessionEnd removes the session's subagent worktrees that hold nothing to lose. It's added
    #   unless already there, and only once git wt is installed. While another command holds WorktreeCreate or
    #   WorktreeRemove, it's removed from all three events. Its 120 s timeout stops a stuck
    #   git wt from holding up claude -w for the default 10 minutes.
    # Status line: ~/.claude/statusline.sh (model, effort, context, 5-hour limit, git branch).
    #   Refresh every five seconds, including while idle. Other keys, such as padding, stay.
    # Send Anthropic less: no error reports, session quality surveys (they can attach the
    #   transcript), /feedback, or feedback drafts. Training on your chats is an account
    #   setting (see ai_tools/README.md → Privacy). Telemetry stays on: DO_NOT_TRACK and
    #   DISABLE_TELEMETRY also stop Claude Code fetching feature flags, which turns off
    #   /advisor, /skill-doctor, skill and plugin sync, and more. Leave
    #   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC unset: it also turns off Remote Control, so
    #   mobile pushes stop.
    # Each value you can change, with = to write over yours or //= to set it only when unset
    local i op keepable=""
    for i in "${!CLAUDE_CODE_KEEP_PATHS[@]}"; do
        claude_code_keep_applies "$i" || continue
        op="//="
        if "${CLAUDE_CODE_REPLACE[i]}"; then op="="; fi
        keepable+="| ${CLAUDE_CODE_KEEP_PATHS[i]} $op ${CLAUDE_CODE_KEEP_VALUES[i]}"
    done
    # shellcheck disable=SC2016 # jq variables, not shell ones
    local settings='
        def add_hook($command; $timeout):
            (. // []) as $groups
            | if any($groups[].hooks[]?; .command == $command) then $groups
              else $groups + [{"hooks": [{"type": "command", "command": $command, "timeout": $timeout}]}] end;
        # Remove $command from hooks.<$event>, then any group that leaves empty, then the event
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
        # An earlier run may have registered ours before the other command arrived, while the
        # hook's copy was executable, or while git wt was installed
        settings+='| remove_hook("WorktreeCreate"; "'"$hook"'")
            | remove_hook("WorktreeRemove"; "'"$hook"'")
            | remove_hook("SessionEnd"; "'"$hook"'")'
    else
        # SessionEnd hooks get 1.5 s in all unless one sets a longer timeout, up to 60 s, and
        # git wt prune checks each of the session's worktrees
        settings+='| .hooks.WorktreeCreate |= add_hook("'"$hook"'"; 120)
            | .hooks.WorktreeRemove |= add_hook("'"$hook"'"; 120)
            | .hooks.SessionEnd |= add_hook("'"$hook"'"; 30)'
    fi
    printf '%s\n' "$settings"
}

# Usage: configure_claude_code [<register the worktree hook: true|false>]
configure_claude_code() {
    echo "Configuring Claude Code..."
    local settings i
    for i in "${!CLAUDE_CODE_KEEP_PATHS[@]}"; do
        CLAUDE_CODE_REPLACE[i]=false
        claude_code_keep_applies "$i" || continue
        if replace_custom_value "${CLAUDE_CODE_KEEP_NAMES[i]}" "$(claude_code_value "${CLAUDE_CODE_KEEP_PATHS[i]}")" \
            "$(claude_code_keep_wanted "$i")"; then
            CLAUDE_CODE_REPLACE[i]=true
        fi
    done
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

# Pass the status line script and the worktree hook, each as source and destination, to a
# function: copy_file to copy them, or status_file to report them
script_files() {
    local status=0
    "$1" "$DOTFILES_DIR/ai_tools/claude-code/statusline.sh" "$CLAUDE_CODE_STATUSLINE" || status=1
    "$1" "$DOTFILES_DIR/ai_tools/claude-code/worktree-hook.sh" "$CLAUDE_CODE_WORKTREE_HOOK" || status=1
    return "$status"
}

# See user_instructions_to
user_instructions_files() {
    user_instructions_to "$CLAUDE_CODE_INSTRUCTIONS" "$@"
}

install_scripts() {
    echo "  Status line script and worktree hook:"
    local status=0
    script_files copy_file || status=1
    chmod 755 "$CLAUDE_CODE_STATUSLINE" "$CLAUDE_CODE_WORKTREE_HOOK" || status=1
    return "$status"
}

status() {
    local value wanted i line claude
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
    if ! tool_home_is "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; then
        status_item unknown "Claude Code settings, status line, and instructions: $CLAUDE_CODE_HOME_POLICY"
        status_result
        return
    fi
    if status_require_cmd jq "Settings in ~/.claude/settings.json"; then
        status_check "Settings in ~/.claude/settings.json" json_applied "$CLAUDE_CODE_SETTINGS" "$(claude_code_settings)"
        for i in "${!CLAUDE_CODE_KEEP_PATHS[@]}"; do
            claude_code_keep_applies "$i" || continue
            value="$(claude_code_value "${CLAUDE_CODE_KEEP_PATHS[i]}")"
            wanted="$(claude_code_keep_wanted "$i")"
            if [ -n "$value" ] && [ "$value" != "$wanted" ]; then
                status_custom_value "${CLAUDE_CODE_KEEP_NAMES[i]}" "$value" "$wanted"
            fi
        done
    fi
    claude_code_have_git_wt || status_item missing "Worktree hook: $CLAUDE_CODE_NO_GIT_WT"
    while IFS= read -r line; do
        [ -z "$line" ] || status_item missing "Worktree hook: $line, so ours isn't registered; remove it from ~/.claude/settings.json and re-run the step"
    done <<< "$(claude_code_other_worktree_hooks)"
    script_files status_file
    user_instructions_files status_file "merge by hand, or re-run the step from a terminal to replace it"
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    # Anthropic's installer prints "Setting up Claude Code..." itself
    echo "Claude Code:"
    if ! tool_home_is "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; then
        echo "  CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, but $CLAUDE_CODE_HOME_POLICY" >&2
        return 1
    fi
    require_cmd jq || return 1
    # Anthropic's installer downloads with curl
    if ! claude_code_path > /dev/null; then
        require_cmd curl || return 1
    fi
    local status=0
    install_claude_code || status=1
    # The hook goes in place before settings.json registers it. When it isn't there, it isn't
    # registered, and an earlier registration goes, since Claude Code would fail to run it and so
    # fail to create the worktree.
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
