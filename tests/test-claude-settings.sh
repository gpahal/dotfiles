#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The claude-code step's settings merge. It writes no permission rules, only auto mode as the
# default, and keeps any rule you added. It sets the status line's type, command, and a
# five-second refresh interval, keeping other statusLine keys. Those three, the model, each
# model's effort, and Ubuntu's notification channel are values you can change: one of your own is
# kept unless you agree to replace it. They share one loop, so the refresh interval and the effort
# stand in for the rest.

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
replace_fn claude_code_path 'echo "$HOME/.local/bin/claude"'
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude/settings.json"
assert_contains "$RUN_OUTPUT" "ok         Claude Code's status line refresh interval (statusLine.refreshInterval): yours, 11 (the repo's is 5)"
replace_fn is_interactive 'true'
replace_fn confirm 'local reply
echo "$1"
read -r reply
[ "$reply" == y ]'
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

# Each model's effort, which /effort saves, follows the same rule: unset, it's set (medium for Opus
# 5.5, high for Sonnet 5.5). Keep one nested-key preserve/replace case; the interval covers consent.
load_script ai_tools/claude-code/install.sh
replace_fn claude_code_path 'echo "$HOME/.local/bin/claude"'
effort() { jq -r --arg m "$1" '.modelSettings[$m].effortLevel' "$settings"; }
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
assert_eq "medium high" "$(effort claude-opus-5-5) $(effort claude-sonnet-5-5)" "the efforts when they were unset"
jq '.modelSettings["claude-opus-5-5"].effortLevel = "xhigh"' "$settings" > "$settings.new" &&
    mv "$settings.new" "$settings"
mine="$(cat "$settings")"
assert_exit 0 configure_claude_code
assert_eq "$mine" "$(cat "$settings")" "the settings with an effort of your own"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_claude_code
assert_eq medium "$(effort claude-opus-5-5)" "the effort with DOTFILES_ASSUME_YES=1"

# The status line command, and on Ubuntu the notification channel, are set when unset
load_script ai_tools/claude-code/install.sh
replace_fn claude_code_path 'echo "$HOME/.local/bin/claude"'
as_os ubuntu
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
# shellcheck disable=SC2088 # the literal value
assert_eq "~/.claude/statusline.sh ghostty" \
    "$(jq -r '"\(.statusLine.command) \(.preferredNotifChannel)"' "$settings")" "the values set when unset"
# Off Ubuntu, the step leaves the channel alone and status doesn't name it
as_os macos
jq '.preferredNotifChannel = "terminal_bell"' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_claude_code
assert_eq terminal_bell "$(jq -r '.preferredNotifChannel' "$settings")" "the channel off Ubuntu"
run status
assert_not_contains "$RUN_OUTPUT" "preferredNotifChannel"

# Another command already in WorktreeCreate or WorktreeRemove: Claude Code would run both, and each
# create hook makes its own worktree. So neither of ours is registered, the step says why and fails
# after the rest, and status names the other hook.
load_script ai_tools/claude-code/install.sh
replace_fn claude_code_path 'echo "$HOME/.local/bin/claude"'
replace_fn claude_code_have_git_wt 'true'
replace_fn install_claude_code ':'
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

# Our hook with a hand-edited type or timeout gets the step's back, and status flags the drift
# first. Other keys in its entry, and other hooks in its group, stay.
load_script ai_tools/claude-code/install.sh
replace_fn claude_code_path 'echo "$HOME/.local/bin/claude"'
replace_fn claude_code_have_git_wt 'true'
echo '{}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
jq '.hooks.WorktreeCreate[0].hooks[0] += {type: "http", timeout: 5, x: 1}
    | .hooks.SessionEnd[0].hooks[0] |= del(.timeout)
    | .hooks.SessionEnd[0].hooks += [{type: "command", command: "other-hook.sh", timeout: 7}]' \
    "$settings" > "$settings.new" && mv "$settings.new" "$settings"
assert_exit 1 json_applied "$settings" "$(claude_code_settings)"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '[{"hooks":[{"type":"command","command":"~/.claude/hooks/worktree-hook.sh","timeout":120,"x":1}]}]' \
    "$(jq -c '.hooks.WorktreeCreate' "$settings")" "WorktreeCreate after fixing a drifted hook"
assert_eq '[{"hooks":[{"type":"command","command":"~/.claude/hooks/worktree-hook.sh","timeout":30},{"type":"command","command":"other-hook.sh","timeout":7}]}]' \
    "$(jq -c '.hooks.SessionEnd' "$settings")" "SessionEnd after fixing a missing timeout"
json_applied "$settings" "$(claude_code_settings)" || fail "settings not applied after fixing a drifted hook"

# Status reports the sign-in from `claude auth status --json`, which prints loggedIn whether or
# not it exits 0. Logged out, it names the command that signs in. Output it can't read is unknown.
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

# Loading the codex step after this one, as check-ai-settings.sh does, keeps Claude Code's
# keepable values, and loading this step again adds them once
load_script ai_tools/claude-code/install.sh
claude_rows="$(keepable_indexes claude_code | wc -l)"
[ "$claude_rows" -gt 0 ] || fail "no keepable values for Claude Code"
load_script ai_tools/codex/install.sh
assert_eq "$claude_rows" "$(keepable_indexes claude_code | wc -l)" "Claude Code's keepable values after loading codex"
assert_contains "$(claude_code_settings)" "claude-opus-5-5"
load_script ai_tools/claude-code/install.sh
assert_eq "$claude_rows" "$(keepable_indexes claude_code | wc -l)" "Claude Code's keepable values after loading it again"
[ "$(keepable_indexes codex | wc -l)" -gt 0 ] || fail "loading claude-code again dropped codex's values"
test_done
