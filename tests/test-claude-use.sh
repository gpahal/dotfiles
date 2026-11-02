#!/bin/bash

# claude-use and the claude functions in zsh/functions.zsh: the account claude runs, and the Claude
# model selections in T3 Code's settings, which it switches without touching other providers'.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
command -v jq &> /dev/null || skip "jq isn't installed"

USE="$REPO_DIR/ai_tools/claude-code/claude-use.sh"
STATE="$HOME/.local/state/dotfiles/claude-account"
T3="$HOME/.t3/userdata/settings.json"

# Signed in to main only
# shellcheck disable=SC2016 # expanded when the stub runs
stub claude 'if [ "$1 $2" == "auth status" ]; then
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then echo "{\"loggedIn\": false}"; exit 1; fi
    echo "{\"loggedIn\": true}"; exit 0
fi
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-unset} $*"'

use() {
    run "$BASH" "$USE" "$@"
}

use --current
assert_eq main "$RUN_OUTPUT" "the account before any choice"
use
assert_eq "claude runs the main account (~/.claude)." "$RUN_OUTPUT" "what it shows before any choice"
use backup
assert_eq 0 "$RUN_STATUS" "switching without T3 Code's settings"
assert_contains "$RUN_OUTPUT" "claude now runs the backup account (~/.claude-backup)."
assert_contains "$RUN_OUTPUT" "The backup account isn't signed in yet: run claude-backup auth login."
assert_eq backup "$(cat "$STATE")" "the saved account"
use main
assert_not_contains "$RUN_OUTPUT" "signed in"
for args in "other" "main extra" "--current extra"; do
    # shellcheck disable=SC2086 # the words
    use $args
    assert_eq 2 "$RUN_STATUS" "claude-use $args"
done

# Each Claude selection follows, at the top level and per project; Codex's and the providers stay
mkdir -p "${T3%/*}"
printf '%s\n' '{
  "defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "medium"}]},
  "textGenerationModelSelection": {"instanceId": "claudeAgent", "model": "claude-haiku-5-5"},
  "sourceControlWriterModelSelection": {"instanceId": "codex", "model": "gpt-6.1-sol"},
  "providerInstances": {"claudeBackup": {"driver": "claudeAgent", "displayName": "Claude Backup", "config": {"homePath": "~/.claude-backup"}}},
  "projectSettingsOverrides": {
    "p1": {"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-sonnet-5-5"}},
    "p2": {"defaultModelSelection": {"instanceId": "codex", "model": "gpt-6.1-sol"}, "defaultAutoPull": false}
  }
}' > "$T3"
chmod 600 "$T3"
instances() {
    jq -r '[.defaultModelSelection, .textGenerationModelSelection, .sourceControlWriterModelSelection,
        .projectSettingsOverrides.p1.defaultModelSelection, .projectSettingsOverrides.p2.defaultModelSelection]
        | map(.instanceId) | join(" ")' "$T3"
}
before="$(jq -S 'del(.. | .instanceId?)' "$T3")"
assert_idempotent "$BASH" "$USE" backup
assert_contains "$FIRST_OUTPUT" "New T3 Code threads now use Claude Backup."
assert_contains "$RUN_OUTPUT" "claude already runs the backup account"
assert_contains "$RUN_OUTPUT" "New T3 Code threads already use Claude Backup."
assert_eq "claudeBackup claudeBackup codex claudeBackup codex" "$(instances)" "the selections on backup"
assert_eq "$before" "$(jq -S 'del(.. | .instanceId?)' "$T3")" "the rest of T3 Code's settings"
assert_eq -rw------- "$(/bin/ls -l "$T3" | cut -c1-10)" "the settings file's mode"
use
assert_eq "claude runs the backup account (~/.claude-backup).
New T3 Code threads use Claude Backup." "$RUN_OUTPUT" "what it shows on backup"
use main
assert_contains "$RUN_OUTPUT" "New T3 Code threads now use Claude."
assert_eq "claudeAgent claudeAgent codex claudeAgent codex" "$(instances)" "the selections back on main"

# Without the Claude Backup provider, T3 Code would get a default it can't run
jq_edit "$T3" 'del(.providerInstances)'
snapshot "$T3"
use backup
assert_eq 1 "$RUN_STATUS" "switching without T3 Code's Claude Backup provider"
assert_contains "$RUN_OUTPUT" "T3 Code has no Claude Backup provider, so new T3 Code threads are unchanged."
assert_contains "$RUN_OUTPUT" "claude now runs the backup account"
assert_unchanged "$T3" "after switching without the Claude Backup provider"

# Threads on another provider stay on it
printf '%s\n' '{"defaultModelSelection": {"instanceId": "codex", "model": "gpt-6.1-sol"}}' > "$T3"
snapshot "$T3"
use main
assert_eq 0 "$RUN_STATUS" "switching while T3 Code's threads use Codex"
assert_contains "$RUN_OUTPUT" "New T3 Code threads don't use Claude, so they're unchanged."
assert_unchanged "$T3" "after switching while T3 Code's threads use Codex"

# claude follows the choice, and claude-b is claude-backup. Main runs with CLAUDE_CONFIG_DIR
# unset, even from a backup session's shell, and a CLAUDE_CONFIG_DIR of your own wins.
command -v zsh &> /dev/null || skip "zsh isn't installed"
mkdir -p "$SANDBOX/bin"
ln -s "$USE" "$SANDBOX/bin/claude-use"
in_zsh() {
    PATH="$SANDBOX/bin:$PATH" zsh -fc "compdef() { :; }; autoload -U add-zsh-hook
        source '$REPO_DIR/zsh/functions.zsh'; $1"
}
use main > /dev/null
assert_eq "CLAUDE_CONFIG_DIR=unset -p hi" "$(CLAUDE_CONFIG_DIR="$HOME/.claude-backup" in_zsh 'claude -p hi')" "claude on main"
assert_eq "CLAUDE_CONFIG_DIR=$HOME/.claude-backup x" "$(in_zsh 'claude-backup x')" "claude-backup on main"
use backup > /dev/null
assert_eq "CLAUDE_CONFIG_DIR=$HOME/.claude-backup x" "$(in_zsh 'claude x')" "claude on backup"
assert_eq "CLAUDE_CONFIG_DIR=unset x" "$(in_zsh 'claude-main x')" "claude-main on backup"
use main > /dev/null
# An alias expands only in lines parsed after it's defined
assert_eq "CLAUDE_CONFIG_DIR=$HOME/.claude-backup x" "$(in_zsh "eval 'claude-b x'")" "claude-b on main"
assert_eq "CLAUDE_CONFIG_DIR=$SANDBOX/mine x" "$(CLAUDE_CONFIG_DIR="$SANDBOX/mine" in_zsh 'claude x')" \
    "claude with a CLAUDE_CONFIG_DIR of your own"
test_done
