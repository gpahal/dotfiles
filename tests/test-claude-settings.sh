#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The claude-code step's settings merge. It writes no permission rules, only auto mode as the
# default, and keeps any rule you added. It sets the status line's type, command, and a
# five-second refresh interval, keeping other statusLine keys. Those three, the model, each
# model's effort, and Ubuntu's notification channel are values you can change: one of your own is
# kept unless you agree to replace it.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/claude-code/install.sh

command -v jq &> /dev/null || skip "jq isn't installed"

settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

# Your own rules and status line keys stay
echo '{"permissions": {"allow": ["Bash(make lint)"], "deny": ["Read(~/secret)"], "ask": ["Bash(rm *)"]},
    "statusLine": {"command": "old.sh", "padding": 2, "refreshInterval": 11}}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '{"allow":["Bash(make lint)"],"deny":["Read(~/secret)"],"ask":["Bash(rm *)"],"defaultMode":"auto"}' \
    "$(jq -c '.permissions' "$settings")" "permissions after the merge"
assert_eq '{"command":"old.sh","padding":2,"refreshInterval":11,"type":"command"}' \
    "$(jq -c '.statusLine' "$settings")" "statusLine after the merge"
json_applied "$settings" "$(claude_code_settings)" || fail "settings not applied after json_merge"

# A fresh install gets no rules at all
echo '{}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '{"defaultMode":"auto"}' "$(jq -c '.permissions' "$settings")" "permissions on a fresh install"
# worktree.baseRef is left to Claude Code's default, fresh, which the worktree hook assumes too
assert_eq null "$(jq -c '.worktree' "$settings")" "worktree on a fresh install"
# Remote Control stays off until /remote-control turns it on for a session, since a connected
# session can be driven from the phone app; pushes are on, for the sessions that connect
assert_eq false "$(jq -c '.remoteControlAtStartup' "$settings")" "remoteControlAtStartup on a fresh install"
assert_eq true "$(jq -c '.agentPushNotifEnabled' "$settings")" "agentPushNotifEnabled on a fresh install"

# The refresh interval: unset, it's set to 5 without a question. One of your own is kept without a
# terminal, and status names it. With a terminal, setup asks every run and replaces it on yes, and
# DOTFILES_ASSUME_YES=1 answers yes.
export DOTFILES_BACKUP=no
interval() { jq -c '.statusLine.refreshInterval' "$settings"; }
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
assert_eq 5 "$(interval)" "the refresh interval when it was unset"
assert_exit 0 configure_claude_code
assert_contains "$RUN_OUTPUT" "already set"
jq '.statusLine.refreshInterval = 11' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
assert_exit 0 configure_claude_code
assert_contains "$RUN_OUTPUT" "Kept your value for Claude Code's status line refresh interval (statusLine.refreshInterval), 11."
assert_eq 11 "$(interval)" "the refresh interval of your own without a terminal"
assert_contains "$RUN_OUTPUT" "already set"
claude_code_path() { echo "$HOME/.local/bin/claude"; }
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude/settings.json"
assert_contains "$RUN_OUTPUT" "ok         Claude Code's status line refresh interval (statusLine.refreshInterval): yours, 11 (the repo's is 5)"
is_interactive() { true; }
confirm() {
    local reply
    echo "$1"
    read -r reply
    [ "$reply" == y ]
}
assert_exit 0 configure_claude_code <<< n
assert_contains "$RUN_OUTPUT" "(statusLine.refreshInterval) is 11, not the repo's 5. Replace it?"
assert_eq 11 "$(interval)" "the refresh interval after no"
assert_exit 0 configure_claude_code <<< y
assert_eq 5 "$(interval)" "the refresh interval after yes"
# Restore the real confirm and is_interactive
load_script ai_tools/claude-code/install.sh
jq '.statusLine.refreshInterval = 11' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_claude_code
assert_eq 5 "$(interval)" "the refresh interval with DOTFILES_ASSUME_YES=1"

# The model follows the same rule: unset, it's set to Opus 5.5. One of your own, such as /model
# saves, is kept without a terminal and named by status, and replaced on yes or with
# DOTFILES_ASSUME_YES=1.
model() { jq -r '.model' "$settings"; }
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
assert_eq claude-opus-5-5 "$(model)" "the model when it was unset"
jq '.model = "claude-sonnet-5-5"' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
assert_exit 0 configure_claude_code
assert_contains "$RUN_OUTPUT" "Kept your value for Claude Code's model (model), claude-sonnet-5-5."
assert_contains "$RUN_OUTPUT" "already set"
assert_eq claude-sonnet-5-5 "$(model)" "the model of your own without a terminal"
claude_code_path() { echo "$HOME/.local/bin/claude"; }
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude/settings.json"
assert_contains "$RUN_OUTPUT" "ok         Claude Code's model (model): yours, claude-sonnet-5-5 (the repo's is claude-opus-5-5)"
is_interactive() { true; }
confirm() {
    local reply
    echo "$1"
    read -r reply
    [ "$reply" == y ]
}
assert_exit 0 configure_claude_code <<< n
assert_contains "$RUN_OUTPUT" "Claude Code's model (model) is claude-sonnet-5-5, not the repo's claude-opus-5-5. Replace it?"
assert_eq claude-sonnet-5-5 "$(model)" "the model after no"
assert_exit 0 configure_claude_code <<< y
assert_eq claude-opus-5-5 "$(model)" "the model after yes"
# Restore the real confirm and is_interactive
load_script ai_tools/claude-code/install.sh
jq '.model = "claude-sonnet-5-5"' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_claude_code
assert_eq claude-opus-5-5 "$(model)" "the model with DOTFILES_ASSUME_YES=1"

# Each model's effort, which /effort saves, follows the same rule: unset, it's set (medium for Opus
# 5.5, high for Sonnet 5.5). One of your own is kept without a terminal and named by status, and
# replaced with DOTFILES_ASSUME_YES=1.
load_script ai_tools/claude-code/install.sh
claude_code_path() { echo "$HOME/.local/bin/claude"; }
effort() { jq -r --arg m "$1" '.modelSettings[$m].effortLevel' "$settings"; }
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
assert_eq "medium high" "$(effort claude-opus-5-5) $(effort claude-sonnet-5-5)" "the efforts when they were unset"
jq '.modelSettings["claude-opus-5-5"].effortLevel = "xhigh"' "$settings" > "$settings.new" &&
    mv "$settings.new" "$settings"
mine="$(cat "$settings")"
assert_exit 0 configure_claude_code
assert_contains "$RUN_OUTPUT" "Kept your value for Claude Code's claude-opus-5-5 effort (modelSettings.claude-opus-5-5.effortLevel), xhigh."
assert_contains "$RUN_OUTPUT" "already set"
assert_eq "$mine" "$(cat "$settings")" "the settings with an effort of your own"
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude/settings.json"
assert_contains "$RUN_OUTPUT" "ok         Claude Code's claude-opus-5-5 effort (modelSettings.claude-opus-5-5.effortLevel): yours, xhigh (the repo's is medium)"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_claude_code
assert_eq medium "$(effort claude-opus-5-5)" "the effort with DOTFILES_ASSUME_YES=1"

# The status line command, and on Ubuntu the notification channel, follow the same rule
load_script ai_tools/claude-code/install.sh
claude_code_path() { echo "$HOME/.local/bin/claude"; }
is_ubuntu() { true; }
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
# shellcheck disable=SC2088 # the literal value
assert_eq "~/.claude/statusline.sh ghostty" \
    "$(jq -r '"\(.statusLine.command) \(.preferredNotifChannel)"' "$settings")" "the values set when unset"
jq '.statusLine.command = "mine.sh" | .preferredNotifChannel = "terminal_bell"' "$settings" > "$settings.new" &&
    mv "$settings.new" "$settings"
mine="$(cat "$settings")"
assert_exit 0 configure_claude_code
assert_contains "$RUN_OUTPUT" "Kept your value for Claude Code's status line command (statusLine.command), mine.sh."
assert_contains "$RUN_OUTPUT" "Kept your value for Claude Code's notification channel (preferredNotifChannel), terminal_bell."
assert_contains "$RUN_OUTPUT" "already set"
assert_eq "$mine" "$(cat "$settings")" "the settings with a status line and channel of your own"
run status
assert_contains "$RUN_OUTPUT" "ok         Claude Code's status line command (statusLine.command): yours, mine.sh (the repo's is ~/.claude/statusline.sh)"
assert_contains "$RUN_OUTPUT" "ok         Claude Code's notification channel (preferredNotifChannel): yours, terminal_bell (the repo's is ghostty)"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_claude_code
# shellcheck disable=SC2088 # the literal value
assert_eq "~/.claude/statusline.sh ghostty" \
    "$(jq -r '"\(.statusLine.command) \(.preferredNotifChannel)"' "$settings")" \
    "the values with DOTFILES_ASSUME_YES=1"
# Off Ubuntu, the step leaves the channel alone and status doesn't name it
is_ubuntu() { false; }
jq '.preferredNotifChannel = "terminal_bell"' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_claude_code
assert_eq terminal_bell "$(jq -r '.preferredNotifChannel' "$settings")" "the channel off Ubuntu"
run status
assert_not_contains "$RUN_OUTPUT" "preferredNotifChannel"

# Another command already in WorktreeCreate or WorktreeRemove: Claude Code would run both, and each
# create hook makes its own worktree. So neither of ours is registered, the step says why and fails
# after the rest, and status names the other hook.
load_script ai_tools/claude-code/install.sh
claude_code_path() { echo "$HOME/.local/bin/claude"; }
claude_code_have_git_wt() { true; }
install_claude_code() { :; }
for event in WorktreeCreate WorktreeRemove; do
    jq -n --arg e "$event" '{hooks: {($e): [{hooks: [{type: "command", command: "my-hook.sh"}]}]}}' > "$settings"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "$event already runs my-hook.sh"
    assert_eq '["my-hook.sh"]' "$(jq -c '[.hooks[][].hooks[].command]' "$settings")" "hooks with another $event hook"
    assert_eq claude-opus-5-5 "$(jq -r '.model' "$settings")" "the model with another $event hook"
    run status
    assert_contains "$RUN_OUTPUT" "missing    Worktree hook: $event already runs my-hook.sh"
    assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude/settings.json"
done

# Ours registered by an earlier run, then another command added to WorktreeCreate: the step removes
# ours from WorktreeCreate, WorktreeRemove, and SessionEnd, so the two don't stack, and leaves the
# other command and its group, and the Stop hook it doesn't own
jq -n '{hooks: {
    WorktreeCreate: [{hooks: [{type: "command", command: "~/.claude/hooks/worktree-hook.sh", timeout: 120}]},
        {hooks: [{type: "command", command: "my-hook.sh"}]}],
    WorktreeRemove: [{hooks: [{type: "command", command: "~/.claude/hooks/worktree-hook.sh", timeout: 120}]}],
    SessionEnd: [{hooks: [{type: "command", command: "~/.claude/hooks/worktree-hook.sh", timeout: 30}]}],
    Stop: [{hooks: [{type: "command", command: "~/.claude/hooks/worktree-hook.sh"}]}]}}' > "$settings"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "WorktreeCreate already runs my-hook.sh"
assert_eq '{"WorktreeCreate":[{"hooks":[{"type":"command","command":"my-hook.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"~/.claude/hooks/worktree-hook.sh"}]}]}' \
    "$(jq -c '.hooks' "$settings")" "hooks after removing ours beside another WorktreeCreate hook"
json_applied "$settings" "$(claude_code_settings)" || fail "settings not applied after removing our worktree hook"
run status
assert_contains "$RUN_OUTPUT" "missing    Worktree hook: WorktreeCreate already runs my-hook.sh, so ours isn't registered"
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude/settings.json"

# Status reports the sign-in from `claude auth status --json`, which prints loggedIn whether or
# not it exits 0. Logged out, it names the command that signs in. Output it can't read, or no
# claude, is unknown.
load_script ai_tools/claude-code/install.sh
stub claude 'echo "{\"loggedIn\": $(cat "$(dirname "$STUB_LOG")/logged-in")}"; [ "$(cat "$(dirname "$STUB_LOG")/logged-in")" == true ]'
echo true > "$SANDBOX/logged-in"
run status
assert_contains "$RUN_OUTPUT" "ok         Signed in to Claude Code"
assert_file_contains "$STUB_LOG" "claude auth status --json"
echo false > "$SANDBOX/logged-in"
run status
assert_contains "$RUN_OUTPUT" "missing    Signed in to Claude Code: run claude auth login"
assert_eq 3 "$RUN_STATUS" "status's exit when signed out"
echo '"maybe"' > "$SANDBOX/logged-in"
run status
assert_contains "$RUN_OUTPUT" "unknown    Signed in to Claude Code: claude auth status didn't say"
hide claude
run status
assert_contains "$RUN_OUTPUT" "unknown    Signed in to Claude Code: Claude Code isn't installed"
test_done
