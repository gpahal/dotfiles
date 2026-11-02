#!/bin/bash
# The step's functions call the replaced ones
# shellcheck disable=SC2329

# The claude-code step's settings merge and its worktree hook registration, for both accounts.
# Keepable values share one loop, so a few stand in for all.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script ai_tools/claude-code/install.sh

command -v jq &> /dev/null || skip "jq isn't installed"

settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

echo '{"permissions": {"allow": ["Bash(make lint)"], "deny": ["Read(~/secret)"], "ask": ["Bash(rm *)"]},
    "statusLine": {"command": "old.sh", "padding": 2, "refreshInterval": 11}}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '{"allow":["Bash(make lint)"],"deny":["Read(~/secret)"],"ask":["Bash(rm *)"]}' \
    "$(jq -c '.permissions | del(.defaultMode)' "$settings")" "your permissions after the merge"
assert_eq '{"command":"old.sh","padding":2,"refreshInterval":11,"type":"command"}' \
    "$(jq -c '.statusLine' "$settings")" "statusLine after the merge"
json_applied "$settings" "$(claude_code_settings)" || fail "settings not applied after json_merge"

# A fresh install's permission mode, pinned since a weaker one would be a security change
echo '{}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '{"defaultMode":"auto"}' "$(jq -c '.permissions' "$settings")" "permissions on a fresh install"

# The step afresh, with Claude Code installed
load_claude_step() {
    load_script ai_tools/claude-code/install.sh
    replace_fn claude_code_path 'echo "$HOME/.local/bin/claude"'
}

export DOTFILES_BACKUP=no
interval() { jq -c '.statusLine.refreshInterval' "$settings"; }
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
assert_eq 5 "$(interval)" "the refresh interval when it was unset"
assert_exit 0 configure_claude_code
assert_contains "$RUN_OUTPUT" "already set"
jq_edit "$settings" '.statusLine.refreshInterval = 11'
assert_exit 0 configure_claude_code
assert_contains "$RUN_OUTPUT" "Kept your value for Claude Code's status line refresh interval (statusLine.refreshInterval), 11."
assert_eq 11 "$(interval)" "the refresh interval of your own without a terminal"
assert_contains "$RUN_OUTPUT" "already set"
replace_fn claude_code_path 'echo "$HOME/.local/bin/claude"'
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude/settings.json"
assert_contains "$RUN_OUTPUT" "ok         Claude Code's status line refresh interval (statusLine.refreshInterval): yours, 11 (the repo's is 5)"
answer stdin
assert_exit 0 configure_claude_code <<< n
assert_contains "$RUN_OUTPUT" "(statusLine.refreshInterval) is 11, not the repo's 5. Replace it?"
assert_eq 11 "$(interval)" "the refresh interval after no"
assert_exit 0 configure_claude_code <<< y
assert_eq 5 "$(interval)" "the refresh interval after yes"
answer yes
jq_edit "$settings" '.statusLine.refreshInterval = 11'
assert_exit 0 configure_claude_code
assert_eq 5 "$(interval)" "the refresh interval after a yes without a terminal"

load_claude_step
as_os ubuntu
echo '{}' > "$settings"
assert_exit 0 configure_claude_code
# shellcheck disable=SC2088 # the literal value
assert_eq "~/.claude/statusline.sh ghostty" \
    "$(jq -r '"\(.statusLine.command) \(.preferredNotifChannel)"' "$settings")" "the values set when unset"
as_os macos
jq_edit "$settings" '.preferredNotifChannel = "terminal_bell"'
answer yes
assert_exit 0 configure_claude_code
assert_eq terminal_bell "$(jq -r '.preferredNotifChannel' "$settings")" "the channel off Ubuntu"
run status
assert_not_contains "$RUN_OUTPUT" "preferredNotifChannel"

# Claude Code would run another WorktreeCreate command too, and each makes its own worktree
load_claude_step
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

# Ours is removed from the events it registers once another WorktreeCreate or WorktreeRemove command
# appears, so they don't stack
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

load_claude_step
replace_fn claude_code_have_git_wt 'true'
echo '{}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
jq_edit "$settings" '.hooks.WorktreeCreate[0].hooks[0] += {type: "http", timeout: 5, x: 1}
    | .hooks.SessionEnd[0].hooks[0] |= del(.timeout)
    | .hooks.SessionEnd[0].hooks += [{type: "command", command: "other-hook.sh", timeout: 7}]'
assert_exit 1 json_applied "$settings" "$(claude_code_settings)"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '[{"hooks":[{"type":"command","command":"~/.claude/hooks/worktree-hook.sh","timeout":120,"x":1}]}]' \
    "$(jq -c '.hooks.WorktreeCreate' "$settings")" "WorktreeCreate after fixing a drifted hook"
assert_eq '[{"hooks":[{"type":"command","command":"~/.claude/hooks/worktree-hook.sh","timeout":30},{"type":"command","command":"other-hook.sh","timeout":7}]}]' \
    "$(jq -c '.hooks.SessionEnd' "$settings")" "SessionEnd after fixing a missing timeout"
json_applied "$settings" "$(claude_code_settings)" || fail "settings not applied after fixing a drifted hook"

# `claude auth status --json` exits 1 when signed out, which pipefail mustn't take for unknown
load_script ai_tools/claude-code/install.sh
stub claude 'echo "{\"loggedIn\": false}"; exit 1'
run main --status
assert_contains "$RUN_OUTPUT" "missing    Signed in to Claude Code: run claude-main auth login"
assert_contains "$RUN_OUTPUT" "missing    Signed in to Claude Code's backup account: run claude-backup auth login"
assert_eq 3 "$RUN_STATUS" "status's exit when signed out"

# The steps share keepable.sh, so loading codex mustn't change Claude Code's settings
load_script ai_tools/claude-code/install.sh
claude_settings="$(claude_code_settings)"
load_script ai_tools/codex/install.sh
assert_eq "$claude_settings" "$(claude_code_settings)" "Claude Code's settings after loading codex"

# git wt makes the worktree hook's worktrees, so the hook is registered only with it
load_script ai_tools/claude-code/install.sh
stub claude 'echo "{\"loggedIn\": true}"'
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_DIR/git/bin/git-wt" "$HOME/.local/bin/git-wt"
echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '{"SessionEnd":1,"Stop":1,"WorktreeCreate":1,"WorktreeRemove":1}' \
    "$(jq -cS '.hooks | map_values([.[].hooks[]] | length)' "$settings")" "hooks per event"
assert_eq '["other"]' "$(jq -c '[.hooks.Stop[].hooks[].command]' "$settings")" "Stop hooks"
json_applied "$settings" "$(claude_code_settings)" || fail "settings not applied after json_merge"

# A non-executable hook copy would make Claude Code fail to create worktrees
failures="$TEST_FAILURES"
(
    replace_fn install_claude_code
    # shellcheck disable=SC2016 # expanded when it runs
    replace_fn install_scripts '
        mkdir -p "$(dirname "$CLAUDE_CODE_WORKTREE_HOOK")" && : > "$CLAUDE_CODE_WORKTREE_HOOK"
        chmod 644 "$CLAUDE_CODE_WORKTREE_HOOK"
        return 1'
    assert_exit 1 main
    assert_eq "null null null" \
        "$(jq -r '"\(.hooks.WorktreeCreate) \(.hooks.WorktreeRemove) \(.hooks.SessionEnd)"' "$settings")" \
        "worktree hooks with a hook copy that isn't executable"
    assert_eq '["other"]' "$(jq -c '[.hooks.Stop[].hooks[].command]' "$settings")" "Stop hooks"
    [ "$TEST_FAILURES" -eq "$failures" ]
) || fail "removing the worktree hook's registration"
rm -f "$CLAUDE_CODE_WORKTREE_HOOK"

replace_fn install_claude_code
echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}' > "$settings"
assert_exit 0 main
assert_eq '["SessionEnd","Stop","WorktreeCreate","WorktreeRemove"]' "$(jq -c '.hooks | keys' "$settings")" \
    "hooks registered with git wt"
rm "$HOME/.local/bin/git-wt"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "bash setup.sh git"
assert_eq '["Stop"]' "$(jq -c '.hooks | keys' "$settings")" "hooks left after git wt went"
echo '{}' > "$settings"
assert_exit 1 main
assert_eq "null" "$(jq -c '.hooks' "$settings")" "hooks registered without git wt"
assert_eq "claude-opus-5-5" "$(jq -r '.model' "$settings")" "model set without git wt"
[ -x "$CLAUDE_CODE_WORKTREE_HOOK" ] || fail "the hook script wasn't copied without git wt"
run main --status
assert_contains "$RUN_OUTPUT" "missing    Worktree hook"
assert_eq 3 "$RUN_STATUS" "status exit without git wt"

# The backup account gets the same settings and instructions, and a second run changes nothing
backup="$HOME/.claude-backup/settings.json"
ln -sf "$REPO_DIR/git/bin/git-wt" "$HOME/.local/bin/git-wt"
load_script ai_tools/claude-code/install.sh
# Signed in to main only. Main's check runs with CLAUDE_CONFIG_DIR unset, whatever the shell's is.
# shellcheck disable=SC2016 # expanded when the stub runs
stub claude 'if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then echo "{\"loggedIn\": false}"; exit 1; fi; echo "{\"loggedIn\": true}"'
rm -rf "$HOME/.claude" "$HOME/.claude-backup"
assert_idempotent main
assert_contains "$FIRST_OUTPUT" "Configuring Claude Code backup..."
assert_eq "$(jq -cS . "$settings")" "$(jq -cS . "$backup")" "the backup account's settings beside main's"
cmp -s "$REPO_DIR/ai_tools/user-instructions.md" "$HOME/.claude-backup/CLAUDE.md" || fail "the backup account's instructions"
[ -x "$HOME/.local/bin/claude-use" ] || fail "claude-use wasn't copied"
export CLAUDE_CONFIG_DIR="$HOME/.claude-backup"
run main --status
assert_contains "$RUN_OUTPUT" "ok         Signed in to Claude Code"$'\n'
assert_contains "$RUN_OUTPUT" "missing    Signed in to Claude Code's backup account: run claude-backup auth login"
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.claude-backup/settings.json"
assert_contains "$RUN_OUTPUT" "ok         ~/.claude-backup/CLAUDE.md"
assert_contains "$RUN_OUTPUT" "ok         ~/.local/bin/claude-use"
# A session on the backup account can run the step
assert_exit 0 main
unset CLAUDE_CONFIG_DIR

# Each account keeps a value of its own, and asks about it by its account's name
jq_edit "$backup" '.statusLine.refreshInterval = 11'
answer stdin
assert_exit 0 claude_code_in_backup configure_claude_code <<< n
assert_contains "$RUN_OUTPUT" "Claude Code backup's status line refresh interval (statusLine.refreshInterval) is 11, not the repo's 5. Replace it?"
assert_eq "11 5" "$(jq -r .statusLine.refreshInterval "$backup" "$settings" | paste -sd' ' -)" "each account's refresh interval"
answer no

# Another WorktreeCreate hook in the backup account's settings keeps ours out there only
jq_edit "$backup" '.hooks.WorktreeCreate += [{hooks: [{type: "command", command: "my-hook.sh"}]}]'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Remove the other hook from"$'\n'"  ~/.claude-backup/settings.json, then re-run this step."
assert_eq '["my-hook.sh"]' "$(jq -c '[.hooks.WorktreeCreate[].hooks[].command]' "$backup")" "the backup account's create hooks"
assert_eq '["~/.claude/hooks/worktree-hook.sh"]' "$(jq -c '[.hooks.WorktreeCreate[].hooks[].command]' "$settings")" "main's create hooks"
run main --status
assert_contains "$RUN_OUTPUT" "missing    Worktree hook: WorktreeCreate already runs my-hook.sh, so ours isn't registered in ~/.claude-backup/settings.json"

# Each account trusts ~/Dev and each git repo in it, a worktree too, keeping the rest of its state
load_script ai_tools/claude-code/install.sh
state="$HOME/.claude.json"
backup_state="$HOME/.claude-backup/.claude.json"
trusted() { jq -c '[.projects | to_entries[] | select(.value.hasTrustDialogAccepted == true) | .key] | sort' "$1"; }
# The backup account's settings start afresh, without the hook above that fails the step
rm -f "$backup"
run claude_code_status_trust
assert_contains "$RUN_OUTPUT" "skipped    Trusted folders ~/Dev and its git repos in ~/.claude.json: ~/Dev doesn't exist"
mkdir -p "$HOME/Dev/a/.git" "$HOME/Dev/js/b/.git" "$HOME/Dev/js/notes" "$HOME/Dev/js/wt" \
    "$HOME/Dev/js/b/packages/c/.git"
echo 'gitdir: elsewhere' > "$HOME/Dev/js/wt/.git"
dev_json="[\"$HOME/Dev\",\"$HOME/Dev/a\",\"$HOME/Dev/js/b\",\"$HOME/Dev/js/wt\"]"
echo '{"numStartups": 3, "projects": {"/elsewhere": {"allowedTools": ["x"]},
    "'"$HOME/Dev/a"'": {"hasTrustDialogAccepted": false, "lastCost": 1}}}' > "$state"
chmod 600 "$state"
rm -f "$backup_state"
assert_idempotent main
assert_eq "$dev_json" "$(trusted "$state")" "main's trusted folders"
assert_eq "$dev_json" "$(trusted "$backup_state")" "the backup account's trusted folders"
assert_eq '3 ["x"] 1' "$(jq -c '[.numStartups, .projects["/elsewhere"].allowedTools, .projects["'"$HOME/Dev/a"'"].lastCost]' "$state" | jq -r 'map(tojson) | join(" ")')" \
    "the rest of main's state"
assert_eq "600 600" "$(file_mode "$state") $(file_mode "$backup_state")" "the state files' modes"
run main --status
assert_contains "$RUN_OUTPUT" "ok         Trusted folders ~/Dev and its git repos in ~/.claude.json"
assert_contains "$RUN_OUTPUT" "ok         Trusted folders ~/Dev and its git repos in ~/.claude-backup/.claude.json"

# A repo cloned later shows as missing until the step runs again
mkdir -p "$HOME/Dev/new/.git"
run main --status
assert_contains "$RUN_OUTPUT" "missing    Trusted folders ~/Dev and its git repos in ~/.claude.json"

# The merge waits for Claude Code's lock, and takes over a stale one
mkdir "$state.lock"
snapshot "$state"
# shellcheck disable=SC2034 # the step reads it
CLAUDE_CODE_LOCK_TRIES=2
assert_exit 1 claude_code_trust_dev
assert_contains "$RUN_OUTPUT" "Claude Code held $state.lock too long"
assert_unchanged "$state" "while Claude Code held its lock"
[ -d "$state.lock" ] || fail "the step removed Claude Code's held lock"
touch -t 202001010000 "$state.lock"
assert_exit 0 claude_code_trust_dev
assert_eq "[\"$HOME/Dev\",\"$HOME/Dev/a\",\"$HOME/Dev/js/b\",\"$HOME/Dev/js/wt\",\"$HOME/Dev/new\"]" \
    "$(trusted "$state")" "main's trusted folders after a stale lock"
[ ! -e "$state.lock" ] || fail "the step left the lock behind"
test_done
