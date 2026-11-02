#!/bin/bash
set -euo pipefail

# Install Claude Code and set both accounts' settings, status line, hooks, and instructions.
#
# The main account uses Claude Code's default home, ~/.claude, and the backup account ~/.claude-backup,
# which gets the same settings and instructions. Each also trusts ~/Dev and its git repos
# (ai_tools/lib/dev-trust.sh). claude-use, copied to ~/.local/bin, picks the account that `claude`
# (zsh/functions.zsh) and new T3 Code threads use.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../lib/keepable.sh
source "$DOTFILES_DIR/ai_tools/lib/keepable.sh"
# shellcheck source=../lib/tool-home.sh
source "$DOTFILES_DIR/ai_tools/lib/tool-home.sh"
# shellcheck source=../lib/dev-trust.sh
source "$DOTFILES_DIR/ai_tools/lib/dev-trust.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

CLAUDE_CODE_HOME="$HOME/.claude"
CLAUDE_CODE_BACKUP_HOME="$HOME/.claude-backup"
# The account's settings and instructions, which claude_code_in_backup switches. Both accounts'
# settings name the status line and hook in ~/.claude.
CLAUDE_CODE_NAME="Claude Code"
CLAUDE_CODE_SETTINGS="$CLAUDE_CODE_HOME/settings.json"
CLAUDE_CODE_INSTRUCTIONS="$CLAUDE_CODE_HOME/CLAUDE.md"
# Claude Code's own state, which holds each folder's trust: in HOME for the default home, and in
# the home for any other
CLAUDE_CODE_STATE="$HOME/.claude.json"
CLAUDE_CODE_STATUSLINE="$CLAUDE_CODE_HOME/statusline.sh"
CLAUDE_CODE_WORKTREE_HOOK="$CLAUDE_CODE_HOME/hooks/worktree-hook.sh"
CLAUDE_CODE_USE="$HOME/.local/bin/claude-use"
# Registered without git wt, every `claude -w` and isolated subagent would fail.
CLAUDE_CODE_NO_GIT_WT="git wt isn't installed, so the step didn't register the worktree hook. Run bash setup.sh git, then re-run this step."

# Values of your own are kept (keepable.sh). Built when used, since tests switch the OS after loading.
claude_code_keep_list() {
    CLAUDE_CODE_KEEP=(
        .model '"claude-opus-5-5"' "$CLAUDE_CODE_NAME's model (model)"
        '.modelSettings["claude-opus-5-5"].effortLevel' '"medium"'
        "$CLAUDE_CODE_NAME's claude-opus-5-5 effort (modelSettings.claude-opus-5-5.effortLevel)"
        '.modelSettings["claude-sonnet-5-5"].effortLevel' '"high"'
        "$CLAUDE_CODE_NAME's claude-sonnet-5-5 effort (modelSettings.claude-sonnet-5-5.effortLevel)"
        .statusLine.type '"command"' "$CLAUDE_CODE_NAME's status line type (statusLine.type)"
        .statusLine.command '"~/.claude/statusline.sh"' "$CLAUDE_CODE_NAME's status line command (statusLine.command)"
        .statusLine.refreshInterval 5 "$CLAUDE_CODE_NAME's status line refresh interval (statusLine.refreshInterval)"
    )
    # Over SSH, `auto` notifies nothing when TERM_PROGRAM didn't reach the tmux pane; ghostty's
    # OSC 777 reaches the Mac either way.
    if is_ubuntu; then
        CLAUDE_CODE_KEEP+=(.preferredNotifChannel '"ghostty"' "$CLAUDE_CODE_NAME's notification channel (preferredNotifChannel)")
    fi
}

# claude_code_in_backup <command...>: runs the command on the backup account's settings and
# instructions
claude_code_in_backup() {
    local CLAUDE_CODE_NAME="Claude Code backup" CLAUDE_CODE_SETTINGS="$CLAUDE_CODE_BACKUP_HOME/settings.json" \
        CLAUDE_CODE_INSTRUCTIONS="$CLAUDE_CODE_BACKUP_HOME/CLAUDE.md" \
        CLAUDE_CODE_STATE="$CLAUDE_CODE_BACKUP_HOME/.claude.json"
    "$@"
}

# Succeeds when CLAUDE_CONFIG_DIR is unset or either account's home, as in a session claude-use
# started on the backup account
claude_code_home_ok() {
    tool_home_is "${CLAUDE_CONFIG_DIR:-}" "$CLAUDE_CODE_HOME" ||
        tool_home_is "${CLAUDE_CONFIG_DIR:-}" "$CLAUDE_CODE_BACKUP_HOME"
}

claude_code_read_custom_values() {
    claude_code_keep_list
    read_custom_values "$(jq -c . "$CLAUDE_CODE_SETTINGS" 2>/dev/null)" "${CLAUDE_CODE_KEEP[@]}"
}

# Sets CLAUDE_CODE_REPLACE[k] to true for each value of your own you agree to replace
claude_code_choose_custom_values() {
    local k
    claude_code_read_custom_values
    CLAUDE_CODE_REPLACE=()
    for ((k = 0; k < ${#CLAUDE_CODE_KEEP[@]} / 3; k++)); do
        if replace_custom_value "${CLAUDE_CODE_KEEP[k * 3 + 2]}" "${CUSTOM_VALUES[k * 2]:-}" \
            "${CUSTOM_VALUES[k * 2 + 1]:-}"; then
            CLAUDE_CODE_REPLACE[k]=true
        fi
    done
}

claude_code_status_custom_values() {
    local k current wanted
    claude_code_read_custom_values
    for ((k = 0; k < ${#CLAUDE_CODE_KEEP[@]} / 3; k++)); do
        current="${CUSTOM_VALUES[k * 2]:-}"
        wanted="${CUSTOM_VALUES[k * 2 + 1]:-}"
        [ -z "$current" ] || [ "$current" == "$wanted" ] ||
            status_custom_value "${CLAUDE_CODE_KEEP[k * 3 + 2]}" "$current" "$wanted"
    done
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

# claude_code_signed_in <claude> [<config dir>]: prints true, false, or nothing when unknown. auth
# status exits 1 when logged out. Without a dir it checks ~/.claude with CLAUDE_CONFIG_DIR unset,
# since Claude Code keys macOS's Keychain entry to the variable.
claude_code_signed_in() {
    (
        if [ -n "${2:-}" ]; then
            export CLAUDE_CONFIG_DIR="$2"
        else
            unset CLAUDE_CONFIG_DIR
        fi
        "$1" auth status --json 2>/dev/null
    ) | jq -r 'if .loggedIn == true or .loggedIn == false then .loggedIn else empty end' 2>/dev/null || true
}

# status_claude_code_signed_in <claude> <what> <login command> [<config dir>]
status_claude_code_signed_in() {
    case "$(claude_code_signed_in "$1" "${4:-}")" in
        true) status_item ok "$2" ;;
        false) status_item missing "$2: run $3" ;;
        *) status_item unknown "$2: claude auth status didn't say; run it to see why" ;;
    esac
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
    local k op keepable=""
    claude_code_keep_list
    for ((k = 0; k < ${#CLAUDE_CODE_KEEP[@]} / 3; k++)); do
        op="//="
        [ "${CLAUDE_CODE_REPLACE[k]:-}" != true ] || op="="
        keepable+="| ${CLAUDE_CODE_KEEP[k * 3]} $op ${CLAUDE_CODE_KEEP[k * 3 + 1]}"
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
    echo "Configuring $CLAUDE_CODE_NAME..."
    local settings
    claude_code_choose_custom_values
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

# Prints the jq filter trusting each of dev_trust_dirs, or nothing without ~/Dev
claude_code_trust_filter() {
    local dir filter=""
    while IFS= read -r dir; do
        [ -z "$dir" ] || filter+=" | .projects[$(jq -n --arg d "$dir" '$d')].hasTrustDialogAccepted = true"
    done <<< "$(dev_trust_dirs)"
    [ -z "$filter" ] || printf '.%s\n' "$filter"
}

# Claude Code rewrites its state while holding proper-lockfile's lock, the directory <file>.lock,
# so the merge holds it too, waiting up to 5 s, and makes no backup, as a prompt would keep it
# held. Claude Code keeps its own backups of the file. A lock untouched for a minute is stale, as
# proper-lockfile refreshes a held one's mtime every few seconds.
CLAUDE_CODE_LOCK_TRIES=50
claude_code_trust_dev() {
    local filter shown dir="${CLAUDE_CODE_STATE%/*}" lock="$CLAUDE_CODE_STATE.lock" tries=0 status=0
    shown="$(shown_path "$CLAUDE_CODE_STATE")"
    filter="$(claude_code_trust_filter)"
    if [ -z "$filter" ]; then
        echo "  $(shown_path "$DEV_TRUST_DIR") doesn't exist, so no folders to trust"
        return 0
    fi
    if json_applied "$CLAUDE_CODE_STATE" "$filter"; then
        echo "  ~/Dev and its git repos are already trusted in $shown"
        return 0
    fi
    if ! mkdir -p "$dir" || [ ! -w "$dir" ]; then
        echo "  Couldn't write in $dir, so the folders aren't trusted in $shown." >&2
        return 1
    fi
    until mkdir "$lock" 2>/dev/null; do
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$lock" 2>/dev/null || true
        elif [ "$tries" -ge "$CLAUDE_CODE_LOCK_TRIES" ]; then
            echo "  Claude Code held $lock too long, so the folders aren't trusted yet; re-run the step." >&2
            return 1
        else
            tries=$((tries + 1))
            sleep 0.1
        fi
    done
    # Readable only by you, as Claude Code makes it, since it comes to hold the account's details
    if [ ! -e "$CLAUDE_CODE_STATE" ] && ! (umask 077 && : > "$CLAUDE_CODE_STATE"); then
        echo "  Couldn't create $CLAUDE_CODE_STATE." >&2
        status=1
    else
        DOTFILES_BACKUP=no json_merge "$CLAUDE_CODE_STATE" "$filter" || status=1
    fi
    rmdir "$lock" 2>/dev/null || true
    [ "$status" -ne 0 ] || echo "  Trusted ~/Dev and its git repos in $shown"
    return "$status"
}

script_files() {
    local status=0
    "$1" "$DOTFILES_DIR/ai_tools/claude-code/statusline.sh" "$CLAUDE_CODE_STATUSLINE" || status=1
    "$1" "$DOTFILES_DIR/ai_tools/claude-code/worktree-hook.sh" "$CLAUDE_CODE_WORKTREE_HOOK" || status=1
    "$1" "$DOTFILES_DIR/ai_tools/claude-code/claude-use.sh" "$CLAUDE_CODE_USE" || status=1
    return "$status"
}

user_instructions_files() {
    "$1" "$DOTFILES_DIR/ai_tools/user-instructions.md" "$CLAUDE_CODE_INSTRUCTIONS"
}

install_scripts() {
    echo "  Status line script, worktree hook, and claude-use:"
    script_files copy_file
}

claude_code_status_trust() {
    local filter name
    name="Trusted folders ~/Dev and its git repos in $(shown_path "$CLAUDE_CODE_STATE")"
    filter="$(claude_code_trust_filter)"
    if [ -z "$filter" ]; then
        status_item skipped "$name: $(shown_path "$DEV_TRUST_DIR") doesn't exist"
    else
        status_check "$name" json_applied "$CLAUDE_CODE_STATE" "$filter"
    fi
}

# One account's settings, trusted folders, worktree hook's registration, and instructions
claude_code_status_account() {
    local line shown
    shown="$(shown_path "$CLAUDE_CODE_SETTINGS")"
    if status_require_cmd jq "Settings in $shown"; then
        status_check "Settings in $shown" json_applied "$CLAUDE_CODE_SETTINGS" "$(claude_code_settings)"
        claude_code_status_custom_values
        claude_code_status_trust
    fi
    while IFS= read -r line; do
        [ -z "$line" ] || status_item missing "Worktree hook: $line, so ours isn't registered in $shown; remove it and re-run the step"
    done <<< "$(claude_code_other_worktree_hooks)"
    user_instructions_files status_file
}

status() {
    local claude
    if claude="$(claude_code_path)"; then
        status_item ok "Claude Code"
        if status_require_cmd jq "Signed in to Claude Code"; then
            status_claude_code_signed_in "$claude" "Signed in to Claude Code" "claude-main auth login"
            status_claude_code_signed_in "$claude" "Signed in to Claude Code's backup account" \
                "claude-backup auth login" "$CLAUDE_CODE_BACKUP_HOME"
        fi
    else
        status_item missing "Claude Code"
        status_item unknown "Signed in to Claude Code: Claude Code isn't installed"
    fi
    if ! claude_code_home_ok && ! tool_home_guard --status "Claude Code settings, status line, and instructions" \
        "Claude Code" CLAUDE_CONFIG_DIR "$CLAUDE_CODE_HOME"; then
        return 0
    fi
    claude_code_status_account
    claude_code_in_backup claude_code_status_account
    claude_code_have_git_wt || status_item missing "Worktree hook: $CLAUDE_CODE_NO_GIT_WT"
    script_files status_file
}

apply() {
    echo "Claude Code:"
    claude_code_home_ok || tool_home_guard "Claude Code" CLAUDE_CONFIG_DIR "$CLAUDE_CODE_HOME" || return 1
    require_cmd jq || return 1
    if ! claude_code_path > /dev/null; then
        require_cmd curl || return 1
    fi
    local status=0
    install_claude_code || status=1
    install_scripts || status=1
    # Register the hook only if its copy is executable; otherwise worktree creation would fail.
    local register_hook=true
    [ -x "$CLAUDE_CODE_WORKTREE_HOOK" ] || register_hook=false
    claude_code_apply_account "$register_hook" || status=1
    claude_code_in_backup claude_code_apply_account "$register_hook" || status=1
    if ! claude_code_have_git_wt; then
        echo "  $CLAUDE_CODE_NO_GIT_WT" >&2
        return 1
    fi
    return "$status"
}

# claude_code_apply_account <register the worktree hook: true|false>: one account's settings,
# trusted folders, and instructions. Fails when another worktree hook kept ours out.
claude_code_apply_account() {
    local status=0 others line
    configure_claude_code "$1" || status=1
    claude_code_trust_dev || status=1
    echo "  User-level instructions:"
    user_instructions_files copy_file || status=1
    others="$(claude_code_other_worktree_hooks)"
    if [ -n "$others" ]; then
        while IFS= read -r line; do
            echo "  $line, so the step didn't register the worktree hook: Claude Code would run both," >&2
        done <<< "$others"
        echo "  and each create hook makes its own worktree. Remove the other hook from" >&2
        echo "  $(shown_path "$CLAUDE_CODE_SETTINGS"), then re-run this step." >&2
        return 1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
