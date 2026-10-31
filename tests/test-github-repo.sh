#!/bin/bash

# github/setup-repo.sh against a gh that keeps the API in files: it reports, changes only after
# you confirm, and a second run changes nothing.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &>/dev/null || skip "jq isn't installed"
load_script github/setup-repo.sh

api="$SANDBOX/gh/api"
mkdir -p "$api"
# Each path is a file named after it, without its query. A write merges its body into the file; a
# body-less PUT turns the setting on. A path listed in $SANDBOX/gh/fail fails its writes, and one in
# $SANDBOX/gh/ignore accepts them and changes nothing, as GitHub does with a setting the plan lacks.
# One in $SANDBOX/gh/forbidden answers 403, as a private repo does for a feature its plan lacks.
stub gh "$(printf 'dir=%q' "$SANDBOX/gh")"'
if [ "$1" == repo ]; then
    cat "$dir/here" 2> /dev/null || { echo "no git remotes found" >&2; exit 1; }
    exit 0
fi
shift
method=GET
if [ "$1" == -X ]; then
    method="$2"
    shift 2
fi
path="${1%%\?*}"
file="$dir/api/$(printf "%s" "$path" | tr / _)"
input=""
[ "${2:-}" != --input ] || input="$(cat)"
if grep -qxF "$path" "$dir/forbidden" 2> /dev/null; then
    echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2
    exit 1
fi
if [ "$method" != GET ] && grep -qxF "$path" "$dir/fail" 2> /dev/null; then
    echo "gh: Server Error (HTTP 500)" >&2
    exit 1
fi
if [ "$method" != GET ] && grep -qxF "$path" "$dir/ignore" 2> /dev/null; then
    exit 0
fi
case "$method" in
    GET)
        [ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        cat "$file"
        ;;
    POST)
        jq ". + {id: 1}" <<< "$input" > "${file}_1"
        echo "[{\"id\": 1, \"name\": \"main\", \"target\": \"branch\"}]" > "$file"
        ;;
    *)
        if [ -z "$input" ]; then
            case "$path" in
                */vulnerability-alerts) : > "$file" ;;
                *) echo "{\"enabled\": true}" > "$file" ;;
            esac
        else
            [ -f "$file" ] || echo "{}" > "$file"
            jq --argjson in "$input" ". * \$in" "$file" > "$file.new"
            mv "$file.new" "$file"
        fi
        ;;
esac'

put() {
    printf '%s\n' "$2" > "$api/$(printf '%s' "$1" | tr / _)"
}

# A repo set up the way the existing ones were
fresh_repo() {
    rm -rf "$api" "$SANDBOX/gh/fail" "$SANDBOX/gh/ignore" "$SANDBOX/gh/forbidden" "$SANDBOX/gh/here"
    mkdir -p "$api"
    put repos/o/r '{"permissions": {"admin": true}, "has_issues": false, "has_projects": false,
        "has_wiki": false, "has_discussions": false, "allow_merge_commit": false,
        "allow_squash_merge": true, "allow_rebase_merge": false,
        "squash_merge_commit_title": "COMMIT_OR_PR_TITLE", "squash_merge_commit_message": "COMMIT_MESSAGES",
        "allow_auto_merge": true, "delete_branch_on_merge": true, "allow_update_branch": true,
        "security_and_analysis": {"secret_scanning": {"status": "enabled"},
            "secret_scanning_push_protection": {"status": "enabled"},
            "secret_scanning_non_provider_patterns": {"status": "disabled"},
            "secret_scanning_validity_checks": {"status": "disabled"}}}'
    put repos/o/r/rulesets '[]'
    put repos/o/r/pulls '[{"head": {"sha": "abc"}}]'
    put repos/o/r/commits/abc/check-runs '{"check_runs": [
        {"name": "lint", "app": {"id": 15368}}, {"name": "check", "app": {"id": 15368}},
        {"name": "Analyze (actions)", "app": {"id": 15368}}, {"name": "Vercel", "app": {"id": 8329}}]}'
    put repos/o/r/actions/permissions '{"enabled": true, "allowed_actions": "all", "sha_pinning_required": false}'
    put repos/o/r/actions/permissions/workflow \
        '{"default_workflow_permissions": "read", "can_approve_pull_request_reviews": false}'
    put repos/o/r/actions/permissions/fork-pr-contributor-approval '{"approval_policy": "first_time_contributors"}'
    put repos/o/r/automated-security-fixes '{"enabled": false, "paused": false}'
    put repos/o/r/private-vulnerability-reporting '{"enabled": false}'
    put repos/o/r/immutable-releases '{"enabled": false, "enforced_by_owner": false}'
    put repos/o/r/code-scanning/default-setup '{"state": "not-configured"}'
}

# A private repo on GitHub Free, which answers 422 for the public repo's fork PR approval and 404 for
# private vulnerability reporting; the stub's 404 for both fails the run if it reads either
private_repo() {
    fresh_repo
    put repos/o/r "$(api_json repos/o/r '. + {private: true, allow_auto_merge: false, security_and_analysis: null}')"
    rm "$api/repos_o_r_actions_permissions_fork-pr-contributor-approval" \
        "$api/repos_o_r_private-vulnerability-reporting"
    put repos/o/r/actions/permissions/fork-pr-workflows-private-repos \
        '{"run_workflows_from_fork_pull_requests": false, "send_write_tokens_to_workflows": false,
        "send_secrets_and_variables": false, "require_approval_for_fork_pr_workflows": false}'
    printf '%s\n' repos/o/r/rulesets repos/o/r/code-scanning/default-setup > "$SANDBOX/gh/forbidden"
}

api_json() {
    jq -c "$2" "$api/$(printf '%s' "$1" | tr / _)"
}

assert_no_writes() {
    assert_file_not_contains "$STUB_LOG" "gh api -X"
}

# A missing gh fails before anything else runs
fresh_repo
(
    hide gh
    assert_exit 1 main o/r
    assert_contains "$RUN_OUTPUT" "gh isn't installed"
)

assert_exit 2 main not-a-repo
assert_exit 2 main --checks
assert_exit 2 main --bogus o/r
assert_exit 2 main o/r o/s
# Outside a checkout, with no repo named
assert_exit 2 main
assert_contains "$RUN_OUTPUT" "isn't a checkout of a GitHub repo"

# --check reports every difference and changes nothing; with no ruleset, the latest PR's aggregate
# check is the one to require
assert_read_only 3 main --check o/r
assert_no_writes
assert_contains "$RUN_OUTPUT" "change  Issues on: false, wants true"
assert_contains "$RUN_OUTPUT" "change  Squash commits take the PR title and description: COMMIT_OR_PR_TITLE and COMMIT_MESSAGES, wants PR_TITLE and PR_BODY"
assert_contains "$RUN_OUTPUT" "Required status checks: check"$'\n'
assert_contains "$RUN_OUTPUT" "change  Main ruleset: PRs, squash only, signed linear history, no force pushes, the checks: missing, wants standard"
assert_contains "$RUN_OUTPUT" "change  Dependabot alerts: off, wants on"
assert_contains "$RUN_OUTPUT" "change  Dependabot version updates in .github/dependabot.yml: missing, wants present"
assert_contains "$RUN_OUTPUT" "ok      Projects off"
assert_contains "$RUN_OUTPUT" "12 settings differ from the standard."

# Declining changes nothing
answer no
assert_exit 0 main o/r
assert_no_writes
assert_contains "$RUN_OUTPUT" "Nothing was changed."

# Applying in a checkout of the repo sets everything, copies dependabot.yml for you to commit, and
# a second run changes nothing
checkout="$SANDBOX/checkout"
mkdir -p "$checkout"
git -C "$checkout" init -q
echo o/r > "$SANDBOX/gh/here"
answer yes
cd "$checkout"
assert_idempotent main
cd "$SANDBOX"
assert_contains "$FIRST_OUTPUT" "Set: Issues on"
assert_contains "$FIRST_OUTPUT" "Wrote $checkout/.github/dependabot.yml; commit it in a PR."
assert_contains "$RUN_OUTPUT" "$checkout/.github/dependabot.yml is in the checkout; commit it in a PR."
assert_no_writes
assert_eq "$(cat "$REPO_DIR/github/dependabot.yml")" "$(cat "$checkout/.github/dependabot.yml")" \
    "the copied dependabot.yml"
assert_eq '["PR_TITLE","PR_BODY",true]' \
    "$(api_json repos/o/r '[.squash_merge_commit_title, .squash_merge_commit_message, .has_issues]')" \
    "the repo's settings"
assert_eq '[{"context":"check","integration_id":15368}]' \
    "$(api_json repos/o/r/rulesets_1 '.rules[] | select(.type == "required_status_checks")
        | .parameters.required_status_checks')" "the ruleset's required checks"
assert_eq '"all_external_contributors"' \
    "$(api_json repos/o/r/actions/permissions/fork-pr-contributor-approval .approval_policy)" \
    "the fork PR approval policy"
# Only the file, which needs a PR, is left; once it's merged the repo matches
assert_read_only 3 main --check o/r
assert_contains "$RUN_OUTPUT" "1 settings differ from the standard."
put repos/o/r/contents/.github/dependabot.yml '{}'
assert_read_only 0 main --check o/r
assert_contains "$RUN_OUTPUT" "o/r matches the standard."

# Outside a checkout, it says where to get the file
fresh_repo
assert_exit 0 main o/r
assert_contains "$RUN_OUTPUT" "Add .github/dependabot.yml in a PR: run this in a checkout of o/r"

# An existing ruleset keeps its checks, ignores parameters the standard leaves out, and is updated
# in place when a rule differs
fresh_repo
put repos/o/r/rulesets '[{"id": 7, "name": "main", "target": "branch"}]'
main_ruleset() {
    jq -c --arg checks "$1" '. + {id: 7} | .rules[4].parameters.require_extra_approval_for_unattributed_changes = true
        | .rules[5].parameters.required_status_checks[0].context = $checks' <<< "$(CHECKS=x ruleset_json)"
}
put repos/o/r/rulesets/7 "$(main_ruleset checks)"
assert_read_only 3 main --check o/r
assert_contains "$RUN_OUTPUT" "Required status checks: checks"$'\n'
assert_contains "$RUN_OUTPUT" "ok      Main ruleset"
put repos/o/r/rulesets/7 "$(main_ruleset checks | jq -c 'del(.rules[3])')"
assert_exit 0 main o/r
assert_contains "$RUN_OUTPUT" "change  Main ruleset: PRs, squash only, signed linear history, no force pushes, the checks: differs, wants standard"
assert_eq '["checks"]' "$(api_json repos/o/r/rulesets/7 '[.rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[].context]')" "the updated ruleset's checks"
assert_eq 1 "$(api_json repos/o/r/rulesets/7 '[.rules[] | select(.type == "required_signatures")] | length')" \
    "the updated ruleset's signing rule"

# --checks replaces them, and none drops the rule
assert_read_only 3 main --check --checks 'lint, check' o/r
assert_contains "$RUN_OUTPUT" "Required status checks: lint, check"$'\n'
assert_contains "$RUN_OUTPUT" "change  Main ruleset"
assert_exit 0 main --checks none o/r
assert_eq 0 "$(api_json repos/o/r/rulesets/7 '[.rules[] | select(.type == "required_status_checks")] | length')" \
    "the status checks rule with --checks none"

# In a terminal it offers the checks to edit, listing the latest PR's
fresh_repo
wrap_fn is_interactive 'return 0'
assert_exit 0 main o/r <<< 'lint,check'
assert_contains "$RUN_OUTPUT" "Check runs on o/r's latest PR: check, lint"$'\n'
assert_eq '["lint","check"]' "$(api_json repos/o/r/rulesets_1 '[.rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[].context]')" "the checks typed in"
fresh_repo
assert_exit 0 main o/r <<< ''
assert_eq '["check"]' "$(api_json repos/o/r/rulesets_1 '[.rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[].context]')" "the suggested checks"
restore_fn is_interactive

# A private repo on GitHub Free shows what its plan rules out as n/a, sets the rest, and matches
# the standard apart from those
private_repo
assert_read_only 3 main --check o/r
assert_contains "$RUN_OUTPUT" "n/a     Auto-merge allowed: private repos need GitHub Pro, or Team for an org"
assert_contains "$RUN_OUTPUT" "n/a     Main ruleset: PRs, squash only, signed linear history, no force pushes, the checks: private repos need GitHub Pro"
assert_contains "$RUN_OUTPUT" "n/a     Secret scanning push protection: private repos need GitHub Secret Protection"
assert_contains "$RUN_OUTPUT" "n/a     Private vulnerability reporting: public repos only"
assert_contains "$RUN_OUTPUT" "n/a     CodeQL default setup: private repos need GitHub Code Security"
assert_contains "$RUN_OUTPUT" "change  Fork PR workflows run once you approve, with no write token or secrets"
assert_contains "$RUN_OUTPUT" "9 settings differ from the standard."
assert_not_contains "$RUN_OUTPUT" "Required status checks"
put repos/o/r/contents/.github/dependabot.yml '{}'
assert_idempotent main --checks check o/r
assert_contains "$FIRST_OUTPUT" "Set: Immutable releases"
assert_no_writes
assert_file_not_contains "$FIRST_LOG" "security_and_analysis"
assert_eq '[true,true,false,false]' "$(api_json repos/o/r/actions/permissions/fork-pr-workflows-private-repos \
    '[.run_workflows_from_fork_pull_requests, .require_approval_for_fork_pr_workflows,
        .send_write_tokens_to_workflows, .send_secrets_and_variables]')" "the private fork PR settings"
assert_eq false "$(api_json repos/o/r .allow_auto_merge)" "auto-merge on a private repo"
assert_read_only 0 main --check o/r
assert_contains "$RUN_OUTPUT" "o/r matches the standard, apart from the 6 settings it can't have."

# A 403 from a public repo is an error, not a feature its plan lacks
fresh_repo
echo repos/o/r/code-scanning/default-setup > "$SANDBOX/gh/forbidden"
assert_exit 1 main --check o/r
assert_contains "$RUN_OUTPUT" "Upgrade to GitHub Pro"
assert_contains "$RUN_OUTPUT" "nothing was changed"

# A failed change fails the run after the rest are applied
fresh_repo
echo repos/o/r/immutable-releases > "$SANDBOX/gh/fail"
assert_exit 1 main o/r
assert_contains "$RUN_OUTPUT" "Couldn't set: Immutable releases"
assert_eq true "$(api_json repos/o/r/private-vulnerability-reporting .enabled)" "a setting applied before the failure"

# A change GitHub accepts but ignores fails the run
fresh_repo
echo repos/o/r/private-vulnerability-reporting > "$SANDBOX/gh/ignore"
assert_exit 1 main o/r
assert_contains "$RUN_OUTPUT" "Set: Private vulnerability reporting"
assert_contains "$RUN_OUTPUT" "GitHub didn't keep: Private vulnerability reporting"
assert_not_contains "$RUN_OUTPUT" "GitHub didn't keep: Dependabot version updates"

# A setting it can't read fails before any change
fresh_repo
rm "$api/repos_o_r_actions_permissions"
assert_exit 1 main o/r
assert_contains "$RUN_OUTPUT" "nothing was changed"
assert_no_writes

# Without admin, nothing is read or changed
fresh_repo
put repos/o/r '{"permissions": {"admin": false}}'
assert_exit 1 main o/r
assert_contains "$RUN_OUTPUT" "needs admin"
assert_no_writes

test_done
