#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The T3 Code server filter sets the global worktreeCleanup to custom rules, which take precedence
# over storageCleanup. It sets the writing style without resetting the style's other fields, and
# keeps a default model and effort of your own, a custom Claude instance's included. It writes
# continueThreadsAfterServerUpdate only for T3 Code before 0.0.46. A second run changes nothing.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/t3-code/install.sh
# The installed version is unknown, as with no T3 Code, unless a test sets it
t3_code_version() { echo "${T3_VERSION:-}"; }

settings="$HOME/settings.json"

# apply <fixture>: merge the filter into a settings file holding the fixture, check a second run
# would change nothing, and print the result compactly
apply() {
    printf '%s\n' "$1" > "$settings"
    json_merge "$settings" "$T3_CODE_SERVER_FILTER" > /dev/null
    json_applied "$settings" "$T3_CODE_SERVER_FILTER" || fail "a second run would change: $1"
}

# Worktree cleanup: a global "off" becomes custom with the four rules
rules='{"worktreeAfterDays":30,"worktreeOnMerge":true,"worktreeOnDelete":true,"worktreeUnchanged":true}'
apply '{"worktreeCleanup": {"mode": "off"}}'
assert_eq "{\"mode\":\"custom\",\"rules\":$rules}" "$(jq -c '.worktreeCleanup' "$settings")" "worktreeCleanup from off"

# Custom rules that differ are replaced. Project overrides are left alone, and the storage settings
# get only browser captures' and logs' retention: worktreeCleanup replaces the worktree fields.
apply '{
  "worktreeCleanup": {"mode": "custom", "rules": {"worktreeAfterDays": 7, "worktreeOnMerge": false, "worktreeOnDelete": false, "worktreeUnchanged": false}},
  "projectSettingsOverrides": {"p1": {"worktreeCleanup": {"mode": "off"}}},
  "storageCleanup": {"browserArtifactsAfterDays": 10}
}'
assert_eq "{\"mode\":\"custom\",\"rules\":$rules}" "$(jq -c '.worktreeCleanup' "$settings")" "worktreeCleanup from other rules"
assert_eq '{"mode":"off"}' "$(jq -c '.projectSettingsOverrides.p1.worktreeCleanup' "$settings")" "project override"
assert_eq '{"browserArtifactsAfterDays":30,"logsAfterDays":30}' \
    "$(jq -cS '.storageCleanup' "$settings")" "storageCleanup"

# Writing style: mode and custom instructions are set, and a field the app adds, such as the
# "Follow change request templates" toggle, keeps your value
apply '{"sourceControlWritingStyle": {"mode": "default", "followChangeRequestTemplates": false}}'
assert_eq '{"customInstructions":"Keep titles concise. Use short bullet points in the description.","followChangeRequestTemplates":false,"mode":"custom"}' \
    "$(jq -cS '.sourceControlWritingStyle' "$settings")" "sourceControlWritingStyle"

# The default model and its effort are values you can change. Unset, they're set, with Claude's
# instance and the 1M context window. One of your own is kept without a terminal, and status
# names it. With a terminal, setup asks every run and replaces it on yes, and DOTFILES_ASSUME_YES=1
# answers yes. Context window and instance are set only for the repo's model.
selection() { jq -cS '.defaultModelSelection' "$settings"; }
# choose <fixture>: write the fixture, decide on your values, then apply
choose() {
    printf '%s\n' "$1" > "$settings"
    # Not in a subshell, which would lose the filter it rebuilds
    t3_code_choose_custom_values > "$SANDBOX/choose.out"
    choose_output="$(cat "$SANDBOX/choose.out")"
    json_merge "$settings" "$T3_CODE_SERVER_FILTER" > /dev/null
    json_applied "$settings" "$T3_CODE_SERVER_FILTER" || fail "a second run would change: $1"
}
# shellcheck disable=SC2034 # the step's functions read it
T3_CODE_SETTINGS="$settings"
ours='{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"medium"},{"id":"contextWindow","value":"1m"}]}'
choose '{}'
assert_eq "$ours" "$(selection)" "the model selection when it was unset"
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default model (defaultModelSelection.model): claude-opus-5-5"
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default effort (defaultModelSelection.options effort): medium"

# A model of your own, from another provider, keeps its instance and options
codex='{"instanceId":"codex","model":"gpt-5.5","options":[{"id":"reasoningEffort","value":"high"}]}'
choose "{\"defaultModelSelection\": $codex}"
assert_eq "$codex" "$(selection)" "a model of your own without a terminal"
assert_contains "$choose_output" "Kept your value for T3 Code's default model (defaultModelSelection.model), gpt-5.5. The repo's is claude-opus-5-5."
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default model (defaultModelSelection.model): yours, gpt-5.5 (the repo's is claude-opus-5-5)"
assert_not_contains "$RUN_OUTPUT" "effort"

# An effort of your own on the repo's model is kept, and so is your context window, which goes
# with it
choose '{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "high"}, {"id": "contextWindow", "value": "200k"}]}}'
assert_eq '{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"high"},{"id":"contextWindow","value":"200k"}]}' \
    "$(selection)" "an effort of your own without a terminal"
assert_contains "$choose_output" "Kept your value for T3 Code's default effort (defaultModelSelection.options effort), high. The repo's is medium."
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default effort (defaultModelSelection.options effort): yours, high (the repo's is medium)"

# With a terminal: no keeps your model, yes replaces it, dropping the other provider's options
is_interactive() { true; }
confirm() {
    local reply
    echo "$1"
    read -r reply
    [ "$reply" == y ]
}
printf '%s\n' "{\"defaultModelSelection\": $codex}" > "$settings"
t3_code_choose_custom_values <<< n > "$SANDBOX/choose.out"
assert_contains "$(cat "$SANDBOX/choose.out")" "T3 Code's default model (defaultModelSelection.model) is gpt-5.5, not the repo's claude-opus-5-5. Replace it?"
json_merge "$settings" "$T3_CODE_SERVER_FILTER" > /dev/null
assert_eq "$codex" "$(selection)" "your model after no"
t3_code_choose_custom_values <<< y > /dev/null
json_merge "$settings" "$T3_CODE_SERVER_FILTER" > /dev/null
assert_eq "$ours" "$(selection)" "the model selection after yes"
# Another instance's effort goes with its options when the model is replaced, so it isn't asked about
printf '%s\n' '{"defaultModelSelection": {"instanceId": "codex", "model": "gpt-5.5", "options": [{"id": "effort", "value": "high"}]}}' > "$settings"
t3_code_choose_custom_values <<< y > "$SANDBOX/choose.out"
assert_not_contains "$(cat "$SANDBOX/choose.out")" "effort"
json_merge "$settings" "$T3_CODE_SERVER_FILTER" > /dev/null
assert_eq "$ours" "$(selection)" "the model selection after yes, from another instance with an effort"
load_script ai_tools/t3-code/install.sh
t3_code_version() { echo "${T3_VERSION:-}"; }
# shellcheck disable=SC2034 # the step's functions read it
T3_CODE_SETTINGS="$settings"
printf '%s\n' '{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "high"}]}}' > "$settings"
DOTFILES_ASSUME_YES=1 t3_code_choose_custom_values > /dev/null
json_merge "$settings" "$T3_CODE_SERVER_FILTER" > /dev/null
assert_eq "$ours" "$(selection)" "the model selection with DOTFILES_ASSUME_YES=1"
is_interactive() { false; }
confirm() { false; }

# A custom Claude instance on the repo's model keeps its instance and its effort, without a
# terminal, and status counts the effort
claude_work='{"instanceId":"claude_work","model":"claude-opus-5-5","options":[{"id":"effort","value":"high"}]}'
choose "{\"defaultModelSelection\": $claude_work}"
assert_eq "$claude_work" "$(selection)" "a custom Claude instance's model selection"
assert_contains "$choose_output" "Kept your value for T3 Code's default effort (defaultModelSelection.options effort), high."
run t3_code_status_custom_values
assert_contains "$RUN_OUTPUT" "ok         T3 Code's default effort (defaultModelSelection.options effort): yours, high (the repo's is medium)"
# With the repo's effort, it keeps its instance and gets the 1M context window
choose '{"defaultModelSelection": {"instanceId": "claude_work", "model": "claude-opus-5-5"}}'
assert_eq '{"instanceId":"claude_work","model":"claude-opus-5-5","options":[{"id":"effort","value":"medium"},{"id":"contextWindow","value":"1m"}]}' \
    "$(selection)" "a custom Claude instance's model selection without an effort"

# continueThreadsAfterServerUpdate is written for T3 Code before 0.0.46, which defaults it to false.
# 0.0.46 defaults it to true and drops a key equal to its default, so it isn't written there, nor
# when the version is unknown. A file without it is then already set.
for version in 0.0.45 0.0.9; do
    T3_VERSION="$version" choose '{}'
    assert_eq true "$(jq '.continueThreadsAfterServerUpdate' "$settings")" "continueThreadsAfterServerUpdate on $version"
done
for version in 0.0.46 0.0.46-nightly.20261013.3066 0.1 1.0.0 ""; do
    T3_VERSION="$version" choose '{}'
    assert_eq false "$(jq 'has("continueThreadsAfterServerUpdate")' "$settings")" "continueThreadsAfterServerUpdate on '$version'"
done
assert_exit 0 t3_code_version_older 0.0.45 0.0.46
assert_exit 1 t3_code_version_older 0.0.46 0.0.46
assert_exit 1 t3_code_version_older 0.1 0.0.46
assert_exit 0 t3_code_version_older 0.0.9 0.0.46

# The step reads the version from the t3 CLI on Ubuntu, and from the app's Info.plist on macOS
unset -f t3_code_version
load_script ai_tools/t3-code/install.sh
# shellcheck disable=SC2034 # the step's functions read it
T3_CODE_SETTINGS="$settings"
is_interactive() { false; }
confirm() { false; }
is_macos() { false; }
mkdir -p "$HOME/.local/bin"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "t3 $T3_CLI_VERSION"\n' > "$HOME/.local/bin/t3"
chmod +x "$HOME/.local/bin/t3"
T3_CLI_VERSION=0.0.45 choose '{}'
assert_eq true "$(jq '.continueThreadsAfterServerUpdate' "$settings")" "continueThreadsAfterServerUpdate with t3 0.0.45"
T3_CLI_VERSION=0.0.46 choose '{}'
assert_eq false "$(jq 'has("continueThreadsAfterServerUpdate")' "$settings")" "continueThreadsAfterServerUpdate with t3 0.0.46"
is_macos() { true; }
t3_code_app_path() { echo "$SANDBOX/T3 Code.app"; }
stub plutil '[ "$*" = "-extract CFBundleShortVersionString raw -o - '"$SANDBOX"'/T3 Code.app/Contents/Info.plist" ] && echo "$APP_VERSION"'
APP_VERSION=0.0.45 choose '{}'
assert_eq true "$(jq '.continueThreadsAfterServerUpdate' "$settings")" "continueThreadsAfterServerUpdate with app 0.0.45"
APP_VERSION=0.0.46 choose '{}'
assert_eq false "$(jq 'has("continueThreadsAfterServerUpdate")' "$settings")" "continueThreadsAfterServerUpdate with app 0.0.46"
test_done
