#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The T3 Code server settings filter: what it sets, and which of your values it keeps.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/t3-code/install.sh

settings="$HOME/settings.json"

merge_fixture() {
    printf '%s\n' "$1" > "$settings"
    json_merge "$settings" "$(t3_code_server_filter)" > /dev/null
    json_applied "$settings" "$(t3_code_server_filter)" || fail "a second run would change: $1"
}

rules='{"worktreeAfterDays":30,"worktreeOnDelete":true,"worktreeOnMerge":true,"worktreeSettledAfterDays":15,"worktreeUnchanged":true}'
merge_fixture '{"worktreeCleanup": {"mode": "off"}}'
assert_eq "{\"mode\":\"custom\",\"rules\":$rules}" "$(jq -cS '.worktreeCleanup' "$settings")" "worktreeCleanup from off"

# Project overrides are left alone; worktreeCleanup replaces storageCleanup's worktree fields
merge_fixture '{
  "worktreeCleanup": {"mode": "custom", "rules": {"worktreeAfterDays": 7, "worktreeOnMerge": false, "worktreeOnDelete": false, "worktreeUnchanged": false}},
  "projectSettingsOverrides": {"p1": {"worktreeCleanup": {"mode": "off"}}},
  "storageCleanup": {"browserArtifactsAfterDays": 10}
}'
assert_eq "{\"mode\":\"custom\",\"rules\":$rules}" "$(jq -cS '.worktreeCleanup' "$settings")" "worktreeCleanup from other rules"
assert_eq '{"mode":"off"}' "$(jq -c '.projectSettingsOverrides.p1.worktreeCleanup' "$settings")" "project override"
assert_eq '{"browserArtifactsAfterDays":30,"logsAfterDays":30}' \
    "$(jq -cS '.storageCleanup' "$settings")" "storageCleanup"

# A rule the filter doesn't set keeps its value
merge_fixture '{"worktreeCleanup": {"mode": "custom", "rules": {"worktreeKeepWhen": "tracked-changes", "worktreeAfterDays": 7, "worktreeSettledAfterDays": null}}}'
assert_eq '{"mode":"custom","rules":{"worktreeAfterDays":30,"worktreeKeepWhen":"tracked-changes","worktreeOnDelete":true,"worktreeOnMerge":true,"worktreeSettledAfterDays":15,"worktreeUnchanged":true}}' \
    "$(jq -cS '.worktreeCleanup' "$settings")" "worktreeCleanup with rules from a newer T3 Code"

# Other writing style fields keep your value
merge_fixture '{"sourceControlWritingStyle": {"mode": "default", "followChangeRequestTemplates": false}}'
assert_eq '{"customInstructions":"Keep titles concise. Use short bullet points in the description.","followChangeRequestTemplates":false,"mode":"custom"}' \
    "$(jq -cS '.sourceControlWritingStyle' "$settings")" "sourceControlWritingStyle"

# A model or effort of your own is kept without a terminal and replaced on yes with one
selection() { jq -cS '.defaultModelSelection' "$settings"; }
choose() {
    printf '%s\n' "$1" > "$settings"
    # Not in a subshell, which would lose the filter it rebuilds
    t3_code_choose_custom_values > "$SANDBOX/choose.out"
    choose_output="$(cat "$SANDBOX/choose.out")"
    json_merge "$settings" "$(t3_code_server_filter)" > /dev/null
    json_applied "$settings" "$(t3_code_server_filter)" || fail "a second run would change: $1"
}
# shellcheck disable=SC2034 # the step's functions read it
T3_CODE_SETTINGS="$settings"
ours='{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"medium"},{"id":"contextWindow","value":"1m"}]}'
choose '{}'
assert_eq "$ours" "$(selection)" "the model selection when it was unset"
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default model (defaultModelSelection.model): claude-opus-5-5"
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default effort (defaultModelSelection.options effort): medium"

codex='{"instanceId":"codex","model":"gpt-5.5","options":[{"id":"reasoningEffort","value":"high"}]}'
choose "{\"defaultModelSelection\": $codex}"
assert_eq "$codex" "$(selection)" "a model of your own without a terminal"
assert_contains "$choose_output" "Kept your value for T3 Code's default model (defaultModelSelection.model), gpt-5.5. The repo's is claude-opus-5-5."
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default model (defaultModelSelection.model): yours, gpt-5.5 (the repo's is claude-opus-5-5)"
assert_not_contains "$RUN_OUTPUT" "effort"

# Your context window goes with your effort
choose '{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "high"}, {"id": "contextWindow", "value": "200k"}]}}'
assert_eq '{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"high"},{"id":"contextWindow","value":"200k"}]}' \
    "$(selection)" "an effort of your own without a terminal"
assert_contains "$choose_output" "Kept your value for T3 Code's default effort (defaultModelSelection.options effort), high. The repo's is medium."
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default effort (defaultModelSelection.options effort): yours, high (the repo's is medium)"

replace_fn is_interactive 'true'
replace_fn confirm 'local reply
echo "$1"
read -r reply
[ "$reply" == y ]'
printf '%s\n' "{\"defaultModelSelection\": $codex}" > "$settings"
t3_code_choose_custom_values <<< y > /dev/null
json_merge "$settings" "$(t3_code_server_filter)" > /dev/null
assert_eq "$ours" "$(selection)" "the model selection after yes"
# Another instance's effort goes with its options, so it isn't asked about
printf '%s\n' '{"defaultModelSelection": {"instanceId": "codex", "model": "gpt-5.5", "options": [{"id": "effort", "value": "high"}]}}' > "$settings"
t3_code_choose_custom_values <<< y > "$SANDBOX/choose.out"
assert_not_contains "$(cat "$SANDBOX/choose.out")" "effort"
json_merge "$settings" "$(t3_code_server_filter)" > /dev/null
assert_eq "$ours" "$(selection)" "the model selection after yes, from another instance with an effort"
replace_fn is_interactive 'false'
replace_fn confirm 'false'

claude_work='{"instanceId":"claude_work","model":"claude-opus-5-5","options":[{"id":"effort","value":"high"}]}'
choose "{\"defaultModelSelection\": $claude_work}"
assert_eq "$claude_work" "$(selection)" "a custom Claude instance's model selection"
assert_contains "$choose_output" "Kept your value for T3 Code's default effort (defaultModelSelection.options effort), high."
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default effort (defaultModelSelection.options effort): yours, high (the repo's is medium)"
choose '{"defaultModelSelection": {"instanceId": "claude_work", "model": "claude-opus-5-5"}}'
assert_eq '{"instanceId":"claude_work","model":"claude-opus-5-5","options":[{"id":"effort","value":"medium"},{"id":"contextWindow","value":"1m"}]}' \
    "$(selection)" "a custom Claude instance's model selection without an effort"

mine='{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"medium"},{"id":"contextWindow","value":"200k"}]}'
choose "{\"defaultModelSelection\": $mine}"
assert_eq "$mine" "$(selection)" "a context window of your own"
choose '{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "medium"}]}}'
assert_eq "$ours" "$(selection)" "the model selection without a context window"
# Replacing your effort or model also sets the repo's context window
replace_fn is_interactive 'true'
replace_fn confirm 'true'
choose '{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "high"}, {"id": "contextWindow", "value": "200k"}]}}'
assert_eq "$ours" "$(selection)" "the model selection after replacing your effort"
choose '{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-sonnet-5", "options": [{"id": "effort", "value": "medium"}, {"id": "contextWindow", "value": "200k"}]}}'
assert_eq "$ours" "$(selection)" "the model selection after replacing your model"
replace_fn is_interactive 'false'
replace_fn confirm 'false'

test_done
