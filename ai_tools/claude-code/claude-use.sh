#!/bin/bash
set -euo pipefail

# claude-use: choose the Claude account that `claude` and new T3 Code threads use.
#
#   claude-use               print the account each uses
#   claude-use main|backup   switch both to that account
#   claude-use --current     print main or backup, for the claude function in zsh/functions.zsh
#
# Main is Claude Code's default home, ~/.claude, and T3 Code's Claude provider. Backup is
# ~/.claude-backup and T3 Code's Claude Backup provider, which the t3-code step adds. Sessions and
# threads already running keep their account. The claude-code step copies this to ~/.local/bin.

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/claude-account"
T3_SETTINGS="$HOME/.t3/userdata/settings.json"
BACKUP_HOME="$HOME/.claude-backup"

# Each model selection on either Claude provider, at the top level and in each project's overrides,
# such as the default model and the one that writes commit messages. T3 Code reloads the file when
# it changes.
# shellcheck disable=SC2016 # jq variables, not shell ones
T3_SELECTIONS='
    def claude: type == "object" and (.instanceId == "claudeAgent" or .instanceId == "claudeBackup");
    def each_settings(f): f | if (.projectSettingsOverrides | type) == "object"
        then .projectSettingsOverrides |= map_values(if type == "object" then f else . end)
        else . end;
    def selections(f): with_entries(if (.key | endswith("ModelSelection")) and (.value | claude)
        then .value |= f else . end);
'

usage() {
    sed -n 's/^#   //p' "$0" >&2
    exit 2
}

current() {
    local account=""
    [ ! -r "$STATE" ] || read -r account < "$STATE" || true
    if [ "$account" == backup ]; then
        echo backup
    else
        echo main
    fi
}

# shellcheck disable=SC2088 # shown, not expanded
home_of() {
    if [ "$1" == backup ]; then
        echo "~/.claude-backup"
    else
        echo "~/.claude"
    fi
}

provider_of() {
    if [ "$1" == backup ]; then
        echo claudeBackup
    else
        echo claudeAgent
    fi
}

provider_name() {
    case "$1" in
        claudeAgent) echo Claude ;;
        claudeBackup) echo "Claude Backup" ;;
        *) echo "$1" ;;
    esac
}

# Prints the provider new T3 Code threads use, or nothing when T3 Code hasn't set one
t3_default() {
    [ -f "$T3_SETTINGS" ] && command -v jq > /dev/null || return 0
    jq -r '.defaultModelSelection.instanceId // empty' "$T3_SETTINGS" 2> /dev/null || true
}

show() {
    local account t3
    account="$(current)"
    echo "claude runs the $account account ($(home_of "$account"))."
    t3="$(t3_default)"
    [ -z "$t3" ] || echo "New T3 Code threads use $(provider_name "$t3")."
}

# Says when the account isn't signed in, which claude auth status reports as loggedIn false. Main
# runs with CLAUDE_CONFIG_DIR unset, since Claude Code keys macOS's Keychain entry to it.
sign_in_hint() {
    local signed_in
    command -v claude > /dev/null && command -v jq > /dev/null || return 0
    signed_in="$(
        if [ "$1" == backup ]; then
            export CLAUDE_CONFIG_DIR="$BACKUP_HOME"
        else
            unset CLAUDE_CONFIG_DIR
        fi
        claude auth status --json 2> /dev/null | jq -r '.loggedIn' 2> /dev/null || true
    )"
    [ "$signed_in" != false ] || echo "The $1 account isn't signed in yet: run claude-$1 auth login."
}

write_state() {
    local dir="${STATE%/*}"
    if ! mkdir -p "$dir" || ! printf '%s\n' "$1" > "$STATE.$$" || ! mv -f "$STATE.$$" "$STATE"; then
        rm -f "$STATE.$$"
        echo "claude-use: couldn't write $STATE" >&2
        return 1
    fi
}

# Points T3 Code's Claude model selections at the account's provider
switch_t3() {
    local id tmp
    id="$(provider_of "$1")"
    [ -f "$T3_SETTINGS" ] || return 0
    if ! command -v jq > /dev/null; then
        echo "claude-use: T3 Code's settings need jq, so new T3 Code threads are unchanged." >&2
        return 1
    fi
    if [ -L "$T3_SETTINGS" ]; then
        echo "claude-use: $T3_SETTINGS is a symlink, so new T3 Code threads are unchanged." >&2
        return 1
    fi
    if [ "$id" == claudeBackup ] &&
        ! jq -e '.providerInstances.claudeBackup | type == "object"' "$T3_SETTINGS" > /dev/null 2>&1; then
        echo "claude-use: T3 Code has no Claude Backup provider, so new T3 Code threads are unchanged." >&2
        echo "Run bash ai_tools/setup.sh t3-code in the dotfiles checkout to add it." >&2
        return 1
    fi
    if ! jq -e "$T3_SELECTIONS"'[each_settings(selections("dotfiles-claude-use"))
            | .. | select(. == "dotfiles-claude-use")] | length > 0' "$T3_SETTINGS" > /dev/null 2>&1; then
        echo "New T3 Code threads don't use Claude, so they're unchanged."
        return 0
    fi
    if jq -e --arg id "$id" "$T3_SELECTIONS"'. == each_settings(selections(.instanceId = $id))' \
        "$T3_SETTINGS" > /dev/null; then
        echo "New T3 Code threads already use $(provider_name "$id")."
        return 0
    fi
    # Beside the file, so the rename is atomic, and a copy, so it keeps the file's mode
    tmp="${T3_SETTINGS%/*}/.settings.json.claude-use.$$"
    if ! cp -p "$T3_SETTINGS" "$tmp" ||
        ! jq --arg id "$id" "$T3_SELECTIONS"'each_settings(selections(.instanceId = $id))' \
            "$T3_SETTINGS" > "$tmp" ||
        ! mv -f "$tmp" "$T3_SETTINGS"; then
        rm -f "$tmp"
        echo "claude-use: couldn't write $T3_SETTINGS, so new T3 Code threads are unchanged." >&2
        return 1
    fi
    echo "New T3 Code threads now use $(provider_name "$id")."
}

switch() {
    local status=0
    if [ "$(current)" == "$1" ] && [ -f "$STATE" ]; then
        echo "claude already runs the $1 account ($(home_of "$1"))."
    else
        write_state "$1" || return 1
        echo "claude now runs the $1 account ($(home_of "$1"))."
    fi
    switch_t3 "$1" || status=1
    sign_in_hint "$1"
    return "$status"
}

case "${1:-}" in
    "") show ;;
    --current)
        [ $# -eq 1 ] || usage
        current
        ;;
    main | backup)
        [ $# -eq 1 ] || usage
        switch "$1"
        ;;
    -h | --help)
        sed -n 's/^#   //p' "$0"
        ;;
    *) usage ;;
esac
