#!/bin/bash
# The step's functions call the OS checks this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The codex step's edit of ~/.codex/config.toml. It pins the built-in workspace-write sandbox and
# keeps everything else: MCP servers, projects, notify, arrays of tables, and your
# [sandbox_workspace_write] settings and permission profiles. A second run changes nothing. The
# status line is a value you can change, which setup keeps unless you agree to replace it.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/codex/install.sh
stub pgrep 'exit 1'
# Codex's sandbox works, where bwrap is installed, as on the Ubuntu runner
stub bwrap
# Signed in, for the status runs below
stub codex 'echo "Logged in using ChatGPT" >&2'
as_os macos

yq --version 2>/dev/null | grep -q mikefarah || skip "mikefarah's yq isn't installed"

# Settings of your own
mkdir -p "$HOME/.codex"
cat > "$CODEX_CONFIG" << 'EOF_CONFIG'
# My settings
notify = ["notify-send", "Codex"]

[sandbox_workspace_write]
writable_roots = ["/tmp/x"]

[permissions.mine]
extends = ":workspace"

[mcp_servers.docs]
command = "npx"
args = ["-y", "docs-mcp"]

[projects."/Users/me/Dev/x"]
trust_level = "trusted"

[[skills.config]]
path = "/a/SKILL.md"
enabled = false

[[skills.config]]
path = "/b/SKILL.md"
enabled = true
EOF_CONFIG

# get <yq path>: print a value of the config as one line of JSON
get() {
    yq -p toml -o json -I=0 "$1" "$CODEX_CONFIG"
}

# set_key <yq path> <value>: set a value in the config, as you or the app would
set_key() {
    yq -i -p toml -o toml "$1 = $2" "$CODEX_CONFIG"
}

assert_exit 0 configure_codex
assert_eq '["notify-send","Codex"]' "$(get .notify)" "notify"
assert_eq '{"command":"npx","args":["-y","docs-mcp"]}' "$(get .mcp_servers.docs)" "mcp_servers.docs"
assert_eq '"trusted"' "$(get '.projects["/Users/me/Dev/x"].trust_level')" "the project's trust level"
assert_eq '[{"path":"/a/SKILL.md","enabled":false},{"path":"/b/SKILL.md","enabled":true}]' \
    "$(get .skills.config)" "skills.config"
assert_file_contains "$CODEX_CONFIG" "# My settings"

# The built-in sandbox, with your writable roots and profiles
assert_eq '"workspace-write"' "$(get .sandbox_mode)" "sandbox_mode"
assert_eq '{"writable_roots":["/tmp/x"]}' "$(get .sandbox_workspace_write)" "[sandbox_workspace_write]"
assert_eq '"on-request"' "$(get .approval_policy)" "approval_policy"
assert_eq '"auto_review"' "$(get .approvals_reviewer)" "approvals_reviewer"
assert_eq '{"mine":{"extends":":workspace"}}' "$(get .permissions)" "your permission profiles"
# The ChatGPT app's settings, on macOS
assert_eq '"squash"' "$(get .desktop.git-pull-request-merge-method)" "a [desktop] key on macOS"

# A second run finds everything set and leaves the file as it was
first="$(cat "$CODEX_CONFIG")"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "status line, and desktop app settings are already set"
assert_eq "$first" "$(cat "$CODEX_CONFIG")" "config.toml after a second run"

# A fresh install gets the sandbox and no profile
rm -f "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '"workspace-write"' "$(get .sandbox_mode)" "sandbox_mode on a fresh install"
assert_eq 'null null' "$(get .default_permissions) $(get .permissions)" "profiles on a fresh install"

# On Ubuntu, the same sandbox, with notifications and MCP tokens set for SSH, and no [desktop]
# keys, since there's no ChatGPT app. Status doesn't expect them, and leaves ones already there.
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
# The MCP tokens Codex keeps in plain text there must be readable only by you. Status says nothing
# of them before there are any.
run status
assert_not_contains "$RUN_OUTPUT" ".credentials.json"
echo '{}' > "$CODEX_CREDENTIALS"
chmod 644 "$CODEX_CREDENTIALS"
run status
assert_contains "$RUN_OUTPUT" "missing    Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you"
# The step sets it, and a second run changes nothing
codex_items
assert_exit 0 items_apply codex_credentials_private
assert_contains "$RUN_OUTPUT" "Made Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you"
assert_eq 600 "$(file_mode "$CODEX_CREDENTIALS")" "the tokens' mode after the step"
assert_exit 0 items_apply codex_credentials_private
assert_eq "" "$RUN_OUTPUT" "a second run's output"
run status
assert_contains "$RUN_OUTPUT" "ok         Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you"
rm -f "$CODEX_CREDENTIALS"

# yq rewrites the file, keeping every value: inline tables, arrays of tables, dotted keys, quoted
# table names, multi-line strings, and full-line comments. A table the step sets that's written
# as dotted keys or an inline table takes the step's keys.
cat > "$CODEX_CONFIG" << 'EOF_CONFIG'
# Mine, at the top
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
# The values, minus those the step sets, sorted so that order doesn't count
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
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "already set"

# A subtable such as Codex's own [tui.model_availability_nux] stays beside a new [tui]
printf 'model = "x"\n\n[tui.model_availability_nux]\n"gpt-6" = 1\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '{"gpt-6":1}' "$(get .tui.model_availability_nux)" "[tui.model_availability_nux] beside a new [tui]"
assert_eq '["model-with-reasoning","current-dir","git-branch","context-used"]' "$(get .tui.status_line)" \
    "the status line beside it"

# Comments after the last key, which yq 4.54.1 drops, are added back, as are those of a file with
# nothing else
printf 'model = "x"\n[tui]\nnotifications = true\n\n# [profiles.fast]\n# model = "y"\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_file_contains "$CODEX_CONFIG" "# [profiles.fast]"
assert_file_contains "$CODEX_CONFIG" '# model = "y"'
printf '# only\n# comments\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_file_contains "$CODEX_CONFIG" "# only"
assert_file_contains "$CODEX_CONFIG" "# comments"
# They go back under the table they were written in, above the tables the edit adds, and a second
# run leaves them there
printf 'model = "x"\n\n[tui]\nnotifications = true\n\n# [profiles.fast]\n# model = "y"\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '# [profiles.fast]|# model = "y"||[analytics]' \
    "$(grep -A3 -F '# [profiles.fast]' "$CODEX_CONFIG" | paste -sd '|' -)" "the trailing comments' place"
first="$(cat "$CODEX_CONFIG")"
assert_exit 0 configure_codex
assert_eq "$first" "$(cat "$CODEX_CONFIG")" "config.toml after a second run with trailing comments"
# Also when yq adds a table above the last one, as a new [tui] above [tui.model_availability_nux]
printf 'model = "x"\n\n[tui.model_availability_nux]\n"gpt-6" = 1\n# "gpt-7" = 1\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq 'gpt-6 = 1||# "gpt-7" = 1||[analytics]' \
    "$(grep -B2 -A2 -F '# "gpt-7"' "$CODEX_CONFIG" | paste -sd '|' -)" "the trailing comment below a new parent table"
# And when yq rewrites the headers, here to [tui] and [desktop]
printf 'model = "x"\n\n[ "tui" ] # mine\nnotifications = true\n  [\x27desktop\x27]\nx = 1\n# y = 2\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq 'x = 1||# y = 2||[analytics]' \
    "$(grep -B2 -A2 -F '# y = 2' "$CODEX_CONFIG" | paste -sd '|' -)" "the trailing comment under a rewritten header"
# A # line inside a multi-line string isn't a comment, though yq turns the string into one line
printf 'developer_instructions = """\n# Style\nBe brief.\n"""\nx = '"'''"'\n# raw\n'"'''"'\n# real\n[tui]\nnotifications = true\n' \
    > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq '"# Style\nBe brief.\n"' "$(get .developer_instructions)" "a multi-line string holding a heading"
assert_file_contains "$CODEX_CONFIG" "# real"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "already set"
# A """ or ''' in an end-of-line comment or a one-line string starts no multi-line string, so the
# comments after it are still kept
for repro in 'model = "o" # wrap in """ if needed\n# keep me\n' \
    'note = "it'"'''"'s"\n[tui]\nnotifications = true\n# keep me\n' \
    "lit = 'say \"\"\"'\n# keep me\n" 'esc = "a\\\\" # """\n# keep me\n'; do
    # shellcheck disable=SC2059 # the fixture's escapes
    printf "$repro" > "$CODEX_CONFIG"
    assert_exit 0 configure_codex
    assert_file_contains "$CODEX_CONFIG" "# keep me"
done
# A rewrite that still drops a comment fails, leaving the file alone
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
# So does one that changes a comment mid-file, though the count of comments comes out even
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

# When yq's rewrite changes a value the step doesn't set, the step fails and leaves the file alone.
# yq 4.54.1 does that to a top-level inline table after a dotted key; a stub stands in for it here.
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

# Invalid TOML fails the step and stays as it was
printf 'model = "x"\n[tui\n' > "$CODEX_CONFIG"
cp "$CODEX_CONFIG" "$SANDBOX/codex-before"
assert_exit 1 configure_codex
assert_contains "$RUN_OUTPUT" "is it valid TOML? Leaving it unchanged."
assert_exit 0 cmp -s "$SANDBOX/codex-before" "$CODEX_CONFIG"

# The step never writes [sandbox_workspace_write]: it isn't added when missing
rm -f "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq null "$(get .sandbox_workspace_write)" "[sandbox_workspace_write] with no config before"

# The footer's items are a value you can change with /statusline. Unset, setup sets them. Set to
# items of your own, they're kept without a terminal, and status names them. With a terminal,
# setup asks every run and replaces them on yes. DOTFILES_ASSUME_YES=1 answers yes.
repo_line='["model-with-reasoning","current-dir","git-branch","context-used"]'
printf 'model = "gpt-6.1-sol"\n' > "$CODEX_CONFIG"
assert_exit 0 configure_codex
assert_eq "$repo_line" "$(get .tui.status_line)" "the status line when it was unset"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "already set"
set_key .tui.status_line '["model", "git-branch"]'
mine="$(cat "$CODEX_CONFIG")"
assert_exit 0 configure_codex
assert_contains "$RUN_OUTPUT" "Kept your value for Codex's status line (tui.status_line), [\"model\",\"git-branch\"]."
assert_eq "$mine" "$(cat "$CODEX_CONFIG")" "the config with a status line of your own"
stub brew 'exit 1'
run status
assert_contains "$RUN_OUTPUT" "ok         Settings in ~/.codex/config.toml"
assert_contains "$RUN_OUTPUT" "ok         Codex's status line (tui.status_line): yours, [\"model\",\"git-branch\"] (the repo's is $repo_line)"
replace_fn is_interactive 'true'
replace_fn confirm 'local reply
echo "$1"
read -r reply
[ "$reply" == y ]'
assert_exit 0 configure_codex <<< n
assert_contains "$RUN_OUTPUT" "Codex's status line (tui.status_line) is [\"model\",\"git-branch\"], not the repo's $repo_line. Replace it?"
assert_eq "$mine" "$(cat "$CODEX_CONFIG")" "the config after no"
assert_exit 0 configure_codex <<< y
assert_eq "$repo_line" "$(get .tui.status_line)" "the status line after yes"
run status
assert_not_contains "$RUN_OUTPUT" "yours"
# Reloading brings back the real confirm and is_interactive
load_script ai_tools/codex/install.sh
as_os macos
printf '%s\n' "$mine" > "$CODEX_CONFIG"
DOTFILES_ASSUME_YES=1 assert_exit 0 configure_codex
assert_eq "$repo_line" "$(get .tui.status_line)" "the status line with DOTFILES_ASSUME_YES=1"

# Status reports the sign-in from `codex login status`, which exits 0 when signed in and prints
# "Not logged in" and exits 1 when not. Signed out, it names the login for the OS. The stubbed
# codex stands in for the cask's.
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

# Status reads the values you can change, and the repo's, with one yq each, rather than one per
# value. The configure phase reads them again once ChatGPT quits: a model the app removed as it
# quit counts as unset, so the repo's is set, though your own was there before.
real_yq="$(command -v yq)"
as_os macos
stub yq 'exec '"$(printf %q "$real_yq")"' "$@"'
: > "$STUB_LOG"
run status
assert_eq 5 "$(grep -c '^yq' "$STUB_LOG")" "yq runs in status: version, values, repo's values, and the settings check"
rm -f "$STUB_DIR/yq"
printf '%s\n' 'model = "mine"' > "$CODEX_CONFIG"
replace_fn ensure_app_quit 'yq -i -p toml -o toml "del(.model)" "$CODEX_CONFIG"'
assert_exit 0 configure_codex
assert_eq '"gpt-6.1-sol"' "$(get .model)" "the model after ChatGPT removed yours as it quit"
load_script ai_tools/codex/install.sh

# A yq older than 4.54.1, or another tool named yq, fails the step before it changes anything, and
# status says to upgrade it. Newer versions, by any part, pass.
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
