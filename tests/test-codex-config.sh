#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/codex/install.sh
stub pgrep 'exit 1'
stub bwrap
stub codex 'echo "Logged in using ChatGPT" >&2'
as_os macos

yq --version 2>/dev/null | grep -q mikefarah || skip "mikefarah's yq isn't installed"

mkdir -p "$HOME/.codex"

get() {
    yq -p toml -o json -I=0 "$1" "$CODEX_CONFIG"
}

set_key() {
    yq -i -p toml -o toml "$1 = $2" "$CODEX_CONFIG"
}

# yq must keep every value and full-line comment through its rewrite
cat > "$CODEX_CONFIG" << 'EOF_CONFIG'
# Mine, at the top
notify = ["notify-send", "Codex"]
model = "x" # end-of-line comment
tui = { theme = "dark" }
developer_instructions = """
line one
line two"""
profile.fast = { model = "a", model_reasoning_effort = "low" }
analytics.enabled = true

[sandbox_workspace_write]
writable_roots = [
    "/a", # mine
    "/b",
]

[permissions.mine]
extends = ":workspace"

# A full-line comment
[mcp_servers.docs]
command = "npx"
args = ["-y", "docs-mcp"]
env = { A = "1", B = "2" }

[projects."/Users/me/Dev/x"]
trust_level = "trusted"

["a.b"]
k = 1

[[skills.config]]
path = "/a/SKILL.md"
enabled = false

[[skills.config]]
path = "/b/SKILL.md"
enabled = true
EOF_CONFIG
step_keys='del(.model_reasoning_effort, .model_verbosity, .model_reasoning_summary, .approval_policy,
    .approvals_reviewer, .sandbox_mode, .analytics, .feedback, .tui.status_line,
    .tui.notification_method, .mcp_oauth_credentials_store, .desktop)'
before="$(yq -p toml -o json -I=0 "$step_keys | sort_keys(..)" "$CODEX_CONFIG")"
assert_exit 0 configure_codex
assert_eq "$before" "$(yq -p toml -o json -I=0 "$step_keys | sort_keys(..)" "$CODEX_CONFIG")" \
    "the config's own values after the edit"
assert_file_contains "$CODEX_CONFIG" "# Mine, at the top"
assert_file_contains "$CODEX_CONFIG" "# A full-line comment"
assert_eq '"line one\nline two"' "$(get .developer_instructions)" "a multi-line string"
assert_eq 'false "dark"' "$(get .analytics.enabled) $(get .tui.theme)" "dotted and inline tables the step sets"
assert_eq '["model-with-reasoning","current-dir","git-branch","context-used"]' "$(get .tui.status_line)" \
    "the status line in an inline [tui]"
assert_eq '"workspace-write"' "$(get .sandbox_mode)" "sandbox_mode"
assert_eq '"on-request"' "$(get .approval_policy)" "approval_policy"
assert_eq '"auto_review"' "$(get .approvals_reviewer)" "approvals_reviewer"
assert_eq '"squash"' "$(get .desktop.git-pull-request-merge-method)" "a [desktop] key on macOS"
first="$(cat "$CODEX_CONFIG")"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "already set"
assert_eq "$first" "$(cat "$CODEX_CONFIG")" "config.toml after a second run"

rm -f "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '"workspace-write"' "$(get .sandbox_mode)" "sandbox_mode on a fresh install"
assert_eq 'null null null' "$(get .default_permissions) $(get .permissions) $(get .sandbox_workspace_write)" \
    "profiles and sandbox table on a fresh install"

as_os ubuntu
rm -f "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '"workspace-write"' "$(get .sandbox_mode)" "sandbox_mode on Ubuntu"
assert_eq null "$(get .desktop)" "[desktop] on Ubuntu"
assert_eq '"osc9"' "$(get .tui.notification_method)" "the notification method on Ubuntu"
assert_eq '"file"' "$(get .mcp_oauth_credentials_store)" "the MCP token store on Ubuntu"
replace_fn bwrap_works 'true'
stub brew 'exit 1'
set_key .desktop.followUpQueueMode '"queue"'
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.codex/config.toml"
assert_not_contains "$RUN_OUTPUT" "followUpQueueMode"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "already set"
assert_eq '"queue"' "$(get .desktop.followUpQueueMode)" "a [desktop] key already there on Ubuntu"
run status
assert_not_contains "$RUN_OUTPUT" ".credentials.json"
echo '{}' > "$CODEX_CREDENTIALS"
chmod 644 "$CODEX_CREDENTIALS"
run status
assert_contains "$RUN_OUTPUT" "missing    Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you"
codex_items
assert_exit 0 items_apply codex_credentials_private
assert_contains "$RUN_OUTPUT" "Made Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you"
assert_eq 600 "$(file_mode "$CODEX_CREDENTIALS")" "the tokens' mode after the step"
assert_exit 0 items_apply codex_credentials_private
assert_eq "" "$RUN_OUTPUT" "a second run's output"
run status
assert_contains "$RUN_OUTPUT" "ok         Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you"
rm -f "$CODEX_CREDENTIALS"

printf 'model = "x"\n\n[tui.model_availability_nux]\n"gpt-6" = 1\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '{"gpt-6":1}' "$(get .tui.model_availability_nux)" "[tui.model_availability_nux] beside a new [tui]"
assert_eq '["model-with-reasoning","current-dir","git-branch","context-used"]' "$(get .tui.status_line)" \
    "the status line beside it"

# yq 4.54.1 drops comments after the last key, so the step adds them back
printf 'model = "x"\n[tui]\nnotifications = true\n\n# [profiles.fast]\n# model = "y"\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_file_contains "$CODEX_CONFIG" "# [profiles.fast]"
assert_file_contains "$CODEX_CONFIG" '# model = "y"'
printf '# only\n# comments\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_file_contains "$CODEX_CONFIG" "# only"
assert_file_contains "$CODEX_CONFIG" "# comments"
printf 'model = "x"\n\n[tui]\nnotifications = true\n\n# [profiles.fast]\n# model = "y"\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '# [profiles.fast]|# model = "y"||[analytics]' \
    "$(grep -A3 -F '# [profiles.fast]' "$CODEX_CONFIG" | paste -sd '|' -)" "the trailing comments' place"
first="$(cat "$CODEX_CONFIG")"
assert_exit 0 configure_codex
assert_eq "$first" "$(cat "$CODEX_CONFIG")" "config.toml after a second run with trailing comments"
printf 'model = "x"\n\n[tui.model_availability_nux]\n"gpt-6" = 1\n# "gpt-7" = 1\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq 'gpt-6 = 1||# "gpt-7" = 1||[analytics]' \
    "$(grep -B2 -A2 -F '# "gpt-7"' "$CODEX_CONFIG" | paste -sd '|' -)" "the trailing comment below a new parent table"
printf 'model = "x"\n\n[ "tui" ] # mine\nnotifications = true\n  [\x27desktop\x27]\nx = 1\n# y = 2\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq 'x = 1||# y = 2||[analytics]' \
    "$(grep -B2 -A2 -F '# y = 2' "$CODEX_CONFIG" | paste -sd '|' -)" "the trailing comment under a rewritten header"
printf 'developer_instructions = """\n# Style\nBe brief.\n"""\nx = '"'''"'\n# raw\n'"'''"'\n# real\n[tui]\nnotifications = true\n' \
    > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '"# Style\nBe brief.\n"' "$(get .developer_instructions)" "a multi-line string holding a heading"
assert_file_contains "$CODEX_CONFIG" "# real"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "already set"
for repro in 'model = "o" # wrap in """ if needed\n# keep me\n' \
    'note = "it'"'''"'s"\n[tui]\nnotifications = true\n# keep me\n' \
    "lit = 'say \"\"\"'\n# keep me\n" 'esc = "a\\\\" # """\n# keep me\n'; do
    # shellcheck disable=SC2059 # the fixture's escapes
    printf "$repro" > "$CODEX_CONFIG"
    assert_exit 0 configure_codex
    assert_file_contains "$CODEX_CONFIG" "# keep me"
done
printf 'model = "x"\n# keep me\n[tui]\nnotifications = true\n' > "$CODEX_CONFIG"
cp "$CODEX_CONFIG" "$SANDBOX/codex-before"
yq() {
    case "$*" in
        *"-o toml"*) command yq "$@" | grep -v '^# keep me' ;;
        *) command yq "$@" ;;
    esac
}
assert_exit 1 configure_codex
assert_contains "$RUN_OUTPUT" "yq would drop comments from $CODEX_CONFIG while editing it; leaving it unchanged."
assert_exit 0 cmp -s "$SANDBOX/codex-before" "$CODEX_CONFIG"
# A changed comment fails even when the comment count matches
printf 'model = "x"\n# keep me\n[tui]\nnotifications = true\n# tail\n' > "$CODEX_CONFIG"
cp "$CODEX_CONFIG" "$SANDBOX/codex-before"
yq() {
    case "$*" in
        *"-o toml"*) command yq "$@" | sed 's/^# keep me$/# other/' ;;
        *) command yq "$@" ;;
    esac
}
assert_exit 1 configure_codex
assert_contains "$RUN_OUTPUT" "yq would drop comments from $CODEX_CONFIG while editing it; leaving it unchanged."
assert_exit 0 cmp -s "$SANDBOX/codex-before" "$CODEX_CONFIG"
unset -f yq

# yq 4.54.1 changes a top-level inline table after a dotted key; the stub stands in for that
printf 'model = "x"\n\n[tui.model_availability_nux]\n"gpt-6" = 1\n' > "$CODEX_CONFIG"
cp "$CODEX_CONFIG" "$SANDBOX/codex-before"
yq() {
    case "$*" in
        *"-o toml"*) command yq "$@" | sed 's/"gpt-6"/"gpt-7"/; s/^gpt-6 /gpt-7 /' ;;
        *) command yq "$@" ;;
    esac
}
assert_exit 1 configure_codex
assert_contains "$RUN_OUTPUT" "yq would change other values in $CODEX_CONFIG while editing it; leaving it unchanged."
assert_exit 0 cmp -s "$SANDBOX/codex-before" "$CODEX_CONFIG"
unset -f yq

printf 'model = "x"\n[tui\n' > "$CODEX_CONFIG"
cp "$CODEX_CONFIG" "$SANDBOX/codex-before"
assert_exit 1 configure_codex
assert_contains "$RUN_OUTPUT" "is it valid TOML? Leaving it unchanged."
assert_exit 0 cmp -s "$SANDBOX/codex-before" "$CODEX_CONFIG"

# test-claude-settings.sh covers the status line consent matrix
repo_line='["model-with-reasoning","current-dir","git-branch","context-used"]'
printf 'model = "gpt-6.1-sol"\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq "$repo_line" "$(get .tui.status_line)" "the status line when it was unset"
set_key .tui.status_line '["model", "git-branch"]'
mine="$(cat "$CODEX_CONFIG")"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "Kept your value for Codex's status line (tui.status_line), [\"model\",\"git-branch\"]."
assert_eq "$mine" "$(cat "$CODEX_CONFIG")" "the config with a status line of your own"
stub brew 'exit 1'
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.codex/config.toml"
assert_contains "$RUN_OUTPUT" "ok         Codex's status line (tui.status_line): yours, [\"model\",\"git-branch\"] (the repo's is $repo_line)"
answer yes
assert_exit 0 configure_codex
assert_eq "$repo_line" "$(get .tui.status_line)" "the status line after yes"
run status
assert_not_contains "$RUN_OUTPUT" "yours"
load_script ai_tools/codex/install.sh
as_os macos

stub brew 'exit 1'
replace_fn codex_cask_path 'echo "$STUB_DIR/codex"'
stub codex 'echo "Logged in using ChatGPT" >&2'
run status
assert_contains "$RUN_OUTPUT" "ok         Signed in to Codex"
assert_file_contains "$STUB_LOG" "codex login status"
stub codex 'echo "Not logged in" >&2; exit 1'
run status
assert_contains "$RUN_OUTPUT" "missing    Signed in to Codex: sign in to the ChatGPT app, or run codex login"
assert_eq 3 "$RUN_STATUS" "status's exit when signed out"
as_os ubuntu
replace_fn bwrap_works 'true'
run status
assert_contains "$RUN_OUTPUT" "missing    Signed in to Codex: run codex login --device-auth (see ai_tools/README.md → Manual steps)"

as_os macos
printf '%s\n' 'model = "mine"' > "$CODEX_CONFIG"
replace_fn ensure_app_quit 'yq -i -p toml -o toml "del(.model)" "$CODEX_CONFIG"'
assert_exit 0 configure_codex
assert_eq '"gpt-6.1-sol"' "$(get .model)" "the model after ChatGPT removed yours as it quit"
load_script ai_tools/codex/install.sh

for version in "v4.54.1" "v4.55.0" "v4.100.0" "v5.0.0"; do
    stub yq "echo 'yq (https://github.com/mikefarah/yq/) version $version'"
    codex_yq_new_enough || fail "yq $version counts as too old"
done
for version in "v4.54.0" "v4.9.9" "v3.99.99"; do
    stub yq "echo 'yq (https://github.com/mikefarah/yq/) version $version'"
    codex_yq_new_enough && fail "yq $version counts as new enough"
done
: > "$STUB_LOG"
run apply
assert_eq 1 "$RUN_STATUS" "apply's exit with yq 3.99.99"
assert_contains "$RUN_OUTPUT" "yq 3.99.99 isn't mikefarah's yq 4.54.1 or newer, which the Codex config edit needs; run brew upgrade yq"
assert_file_not_contains "$STUB_LOG" "brew"
stub yq 'echo "yq 3.4.3"'
run status
assert_contains "$RUN_OUTPUT" "unknown    Settings in ~/.codex/config.toml: yq on PATH isn't mikefarah's yq 4.54.1 or newer"
assert_eq 3 "$RUN_STATUS" "status's exit with another yq"
rm -f "$STUB_DIR/yq"
test_done
