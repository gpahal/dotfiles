#!/bin/bash
set -euo pipefail

# Bring a GitHub repo's settings to the standard below, after you confirm. Setup doesn't run it.
# Usage: bash github/setup-repo.sh [--check] [--checks <a,b>|none] [owner/repo]
# The repo defaults to the current directory's. --check only reports, and exits 3 when anything
# differs. The required status checks default to the main ruleset's, or else to the check runs on
# the latest PR, which it offers to edit. .github/dependabot.yml is a file in the repo, so it only
# copies github/dependabot.yml into a checkout of the repo for you to commit.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

USAGE="Usage: bash github/setup-repo.sh [--check] [--checks <a,b>|none] [owner/repo]"
# GitHub Actions' app ID: a required check only a workflow can satisfy
ACTIONS_APP_ID=15368
DEPENDABOT_FILE=.github/dependabot.yml

# Set by main
REPO=""
CHECK_ONLY=false
CHECKS_GIVEN=false
# Newline-separated
CHECKS=""
# The pending changes, one entry per setting
LABELS=()
METHODS=()
PATHS=()
BODIES=()

# api_get <path>: prints the response; returns 4 on a 404, which some endpoints answer for "off"
api_get() {
    local err status=0
    err="$(mktemp)"
    gh api "$1" 2> "$err" || status=$?
    if [ "$status" -ne 0 ]; then
        if grep -q 'HTTP 404' "$err"; then
            status=4
        else
            cat "$err" >&2
        fi
    fi
    rm -f "$err"
    return "$status"
}

# api_send <method> <path> [JSON body]
api_send() {
    if [ -n "${3:-}" ]; then
        printf '%s\n' "$3" | gh api -X "$1" "$2" --input - > /dev/null
    else
        gh api -X "$1" "$2" > /dev/null
    fi
}

# want <label> <now> <wanted> <method> <path> [JSON body]: reports the setting, and queues the
# change when it differs
want() {
    if [ "$2" == "$3" ]; then
        printf '  ok      %s\n' "$1"
    else
        # JSON strings print without their quotes
        printf '  change  %s: %s, wants %s\n' "$1" "${2//\"/}" "${3//\"/}"
        LABELS+=("$1")
        METHODS+=("$4")
        PATHS+=("$5")
        BODIES+=("${6:-}")
    fi
}

# <label> <api path> <jq filter> <wanted JSON>, for an endpoint that reads and writes one object
want_json() {
    local now
    now="$(api_get "$2" | jq -c "$3")" || return 1
    want "$1" "$now" "$4" "$5" "$2" "${6:-}"
}

# <label> <api path>: an endpoint that answers {"enabled": ...} and is turned on by PUT
want_enabled() {
    want_json "$1" "$2" .enabled true PUT
}

# <label> <field> <wanted JSON>, for a field the repo's PATCH sets
want_repo() {
    want "$1" "$(jq -c ".$2" <<< "$REPO_JSON")" "$3" PATCH "repos/$REPO" \
        "$(jq -cn --arg k "$2" --argjson v "$3" '{($k): $v}')"
}

want_security() {
    want "$1" "$(jq -r ".security_and_analysis.$2.status // \"unavailable\"" <<< "$REPO_JSON")" \
        enabled PATCH "repos/$REPO" \
        "$(jq -cn --arg k "$2" '{security_and_analysis: {($k): {status: "enabled"}}}')"
}

# A 204 means on, a 404 off
want_alerts() {
    local now=on status=0
    api_get "repos/$REPO/vulnerability-alerts" > /dev/null || status=$?
    case "$status" in
        0) ;;
        4) now=off ;;
        *) return 1 ;;
    esac
    want "Dependabot alerts" "$now" on PUT "repos/$REPO/vulnerability-alerts"
}

want_actions() {
    local body
    body='{"enabled":true,"allowed_actions":"all","sha_pinning_required":true}'
    want_json "Actions enabled for all actions" "repos/$REPO/actions/permissions" \
        '[.enabled, .allowed_actions]' '[true,"all"]' PUT "$body" || return 1
    want_json "Actions must be pinned to a full commit SHA" "repos/$REPO/actions/permissions" \
        .sha_pinning_required true PUT "$body" || return 1
    body='{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}'
    want_json "GITHUB_TOKEN is read-only by default" "repos/$REPO/actions/permissions/workflow" \
        .default_workflow_permissions '"read"' PUT "$body" || return 1
    want_json "Actions can create and approve PRs" "repos/$REPO/actions/permissions/workflow" \
        .can_approve_pull_request_reviews true PUT "$body" || return 1
    want_json "Fork PRs from all outside contributors wait for approval" \
        "repos/$REPO/actions/permissions/fork-pr-contributor-approval" .approval_policy \
        '"all_external_contributors"' PUT '{"approval_policy":"all_external_contributors"}'
}

# The main ruleset, with $CHECKS as its required status checks
ruleset_json() {
    jq -cn --arg checks "$CHECKS" --argjson app "$ACTIONS_APP_ID" '{
        name: "main",
        target: "branch",
        enforcement: "active",
        bypass_actors: [],
        conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
        rules: ([
            {type: "deletion"},
            {type: "non_fast_forward"},
            {type: "required_linear_history"},
            {type: "required_signatures"},
            {type: "pull_request", parameters: {
                required_approving_review_count: 0,
                dismiss_stale_reviews_on_push: false,
                require_code_owner_review: false,
                require_last_push_approval: false,
                required_review_thread_resolution: false,
                allowed_merge_methods: ["squash"]
            }}
        ] + ($checks | split("\n") | map(select(. != "")) | if length == 0 then [] else [
            {type: "required_status_checks", parameters: {
                strict_required_status_checks_policy: false,
                do_not_enforce_on_create: false,
                required_status_checks: map({context: ., integration_id: $app})
            }}
        ] end))
    }'
}

# Reads a ruleset on stdin; true when it has the wanted rules and the wanted parameters, ignoring
# parameters the wanted ruleset leaves out
ruleset_matches() {
    jq --argjson w "$1" '. as $e
        | $e.enforcement == $w.enforcement and $e.target == $w.target
        and ($e.bypass_actors // []) == []
        and ($e.conditions.ref_name.include // [] | sort) == $w.conditions.ref_name.include
        and ($e.conditions.ref_name.exclude // []) == []
        and ($e.rules | map(.type) | sort) == ($w.rules | map(.type) | sort)
        and all($w.rules[]; . as $r
            | [$e.rules[] | select(.type == $r.type)][0].parameters as $p
            | all(($r.parameters // {}) | to_entries[];
                if .key == "required_status_checks" then
                    ($p[.key] | map({context, integration_id}) | sort_by(.context))
                        == (.value | sort_by(.context))
                else $p[.key] == .value end))'
}

# The GitHub Actions check runs on the latest PR's head, one per line; CodeQL's left out
detected_checks() {
    local sha
    sha="$(api_get "repos/$REPO/pulls?state=all&per_page=1" | jq -r '.[0].head.sha // empty')" ||
        return 0
    [ -n "$sha" ] || return 0
    api_get "repos/$REPO/commits/$sha/check-runs?per_page=100" |
        jq -r --argjson app "$ACTIONS_APP_ID" '[.check_runs[] | select(.app.id == $app) | .name
            | select(. != "CodeQL" and (startswith("Analyze (") | not))] | unique[]' || true
}

# Sets CHECKS when --checks didn't: the ruleset's, else what the latest PR ran. Applying in a
# terminal offers them to edit.
choose_checks() {
    local detected="" suggested="$1" ask=false reply
    if ! "$CHECK_ONLY" && is_interactive; then
        ask=true
    fi
    if [ -z "$suggested" ] || "$ask"; then
        detected="$(detected_checks)"
    fi
    if [ -z "$suggested" ]; then
        # A repo's aggregate job, which needs the others, is the one to require
        if grep -qx check <<< "$detected"; then
            suggested=check
        elif grep -qx checks <<< "$detected"; then
            suggested=checks
        else
            suggested="$detected"
        fi
    fi
    CHECKS="$suggested"
    if "$ask"; then
        if [ -n "$detected" ]; then
            echo "Check runs on $REPO's latest PR: $(join_lines ', ' <<< "$detected")"
        else
            echo "$REPO has no check runs on a PR to suggest from."
        fi
        reply="$(join_lines , <<< "$suggested")"
        read -r -p "Required status checks, comma-separated, or none [${reply:-none}]: " reply
        [ -z "$reply" ] || CHECKS="$(parse_checks "$reply")"
    fi
}

parse_checks() {
    [ "$1" != none ] || return 0
    tr ',' '\n' <<< "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | { grep -v '^$' || true; }
}

want_ruleset() {
    local list id="" existing="" current="" wanted now=missing method=POST path
    list="$(api_get "repos/$REPO/rulesets?includes_parents=false")" || return 1
    id="$(jq -r '[.[] | select(.name == "main" and .target == "branch")][0].id // empty' <<< "$list")"
    if [ -n "$id" ]; then
        existing="$(api_get "repos/$REPO/rulesets/$id")" || return 1
        current="$(jq -r '.rules[] | select(.type == "required_status_checks")
            | .parameters.required_status_checks[].context' <<< "$existing")"
    fi
    "$CHECKS_GIVEN" || choose_checks "$current"
    wanted="$(ruleset_json)"
    path="repos/$REPO/rulesets"
    if [ -n "$id" ]; then
        now=differs
        method=PUT
        path="$path/$id"
        [ "$(ruleset_matches "$wanted" <<< "$existing")" != true ] || now=standard
    fi
    if [ -n "$CHECKS" ]; then
        echo "  Required status checks: $(join_lines ', ' <<< "$CHECKS")"
    else
        echo "  Required status checks: none"
    fi
    want "Main ruleset: PRs, squash only, signed linear history, no force pushes, the checks" \
        "$now" standard "$method" "$path" "$wanted"
}

# A file in the repo, so it isn't an API change: apply copies it into a checkout to commit
want_dependabot() {
    local status=0
    api_get "repos/$REPO/contents/$DEPENDABOT_FILE" > /dev/null || status=$?
    case "$status" in
        0) want "Dependabot version updates in $DEPENDABOT_FILE" present present FILE "" ;;
        4) want "Dependabot version updates in $DEPENDABOT_FILE" missing present FILE "" ;;
        *) return 1 ;;
    esac
}

# The checkout of $REPO this runs in, if any
checkout_dir() {
    local here
    here="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null)" || return 1
    [ "$here" == "$REPO" ] || return 1
    git rev-parse --show-toplevel 2> /dev/null
}

apply_dependabot() {
    local dir
    if ! dir="$(checkout_dir)"; then
        echo "  Add $DEPENDABOT_FILE in a PR: run this in a checkout of $REPO, or copy $DOTFILES_DIR/github/dependabot.yml."
        return 0
    fi
    if [ -e "$dir/$DEPENDABOT_FILE" ]; then
        echo "  $dir/$DEPENDABOT_FILE is in the checkout; commit it in a PR."
        return 0
    fi
    mkdir -p "$dir/.github"
    cp "$DOTFILES_DIR/github/dependabot.yml" "$dir/$DEPENDABOT_FILE"
    echo "  Wrote $dir/$DEPENDABOT_FILE; commit it in a PR."
}

# Reads every setting, printing each and queueing the changes
plan() {
    want_repo "Issues on" has_issues true
    want_repo "Projects off" has_projects false
    want_repo "Wiki off" has_wiki false
    want_repo "Discussions off" has_discussions false
    want_repo "Merge commits off" allow_merge_commit false
    want_repo "Squash merges on" allow_squash_merge true
    want_repo "Rebase merges off" allow_rebase_merge false
    # GitHub takes the title and message only together, in a few combinations
    want "Squash commits take the PR title and description" \
        "$(jq -r '"\(.squash_merge_commit_title) and \(.squash_merge_commit_message)"' <<< "$REPO_JSON")" \
        "PR_TITLE and PR_BODY" PATCH "repos/$REPO" \
        '{"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
    want_repo "Auto-merge allowed" allow_auto_merge true
    want_repo "Head branches deleted after merge" delete_branch_on_merge true
    want_repo "Update branch suggested" allow_update_branch true
    want_ruleset || return 1
    want_actions || return 1
    want_security "Secret scanning" secret_scanning
    want_security "Secret scanning push protection" secret_scanning_push_protection
    # Non-provider patterns and validity checks are left out: they need GitHub Secret Protection,
    # which personal accounts can't have, and GitHub ignores turning them on without it
    # Dependabot security updates need alerts on first
    want_alerts || return 1
    want_enabled "Dependabot security updates" "repos/$REPO/automated-security-fixes" || return 1
    want_enabled "Private vulnerability reporting" "repos/$REPO/private-vulnerability-reporting" ||
        return 1
    want_json "CodeQL default setup" "repos/$REPO/code-scanning/default-setup" .state \
        '"configured"' PATCH '{"state":"configured","query_suite":"default"}' || return 1
    want_enabled "Immutable releases" "repos/$REPO/immutable-releases" || return 1
    want_dependabot
}

# Reads every setting again, as GitHub accepts some changes it then ignores; fails if one differs
verify() {
    local i left=0
    LABELS=() METHODS=() PATHS=() BODIES=()
    REPO_JSON="$(api_get "repos/$REPO")" || return 1
    plan > /dev/null || return 1
    for ((i = 0; i < ${#LABELS[@]}; i++)); do
        [ "${METHODS[$i]}" != FILE ] || continue
        echo "  GitHub didn't keep: ${LABELS[$i]}" >&2
        left=1
    done
    return "$left"
}

# Applies each queued change, carrying on past a failed one; fails if any did
apply() {
    local i failed=0
    for ((i = 0; i < ${#LABELS[@]}; i++)); do
        if [ "${METHODS[$i]}" == FILE ]; then
            apply_dependabot
        elif api_send "${METHODS[$i]}" "${PATHS[$i]}" "${BODIES[$i]}"; then
            echo "  Set: ${LABELS[$i]}"
        else
            echo "  Couldn't set: ${LABELS[$i]}" >&2
            failed=1
        fi
    done
    return "$failed"
}

main() {
    LABELS=() METHODS=() PATHS=() BODIES=()
    CHECK_ONLY=false CHECKS_GIVEN=false CHECKS="" REPO=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) CHECK_ONLY=true ;;
            --checks)
                [ $# -gt 1 ] || { echo "$USAGE" >&2; return 2; }
                CHECKS_GIVEN=true
                CHECKS="$(parse_checks "$2")"
                shift
                ;;
            -*)
                echo "$USAGE" >&2
                return 2
                ;;
            *)
                [ -z "$REPO" ] || { echo "$USAGE" >&2; return 2; }
                REPO="$1"
                ;;
        esac
        shift
    done
    require_cmd gh || return 1
    require_cmd jq || return 1
    if [ -z "$REPO" ]; then
        REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null)" || {
            echo "This isn't a checkout of a GitHub repo; name one: $USAGE" >&2
            return 2
        }
    fi
    if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "$REPO isn't an owner/repo. $USAGE" >&2
        return 2
    fi
    REPO_JSON="$(api_get "repos/$REPO")" || {
        echo "Couldn't read $REPO; check the name and gh auth status." >&2
        return 1
    }
    if [ "$(jq -r .permissions.admin <<< "$REPO_JSON")" != true ]; then
        echo "Changing $REPO's settings needs admin on it." >&2
        return 1
    fi
    echo "$REPO:"
    plan || {
        echo "Couldn't read all of $REPO's settings, so nothing was changed." >&2
        return 1
    }
    if [ ${#LABELS[@]} -eq 0 ]; then
        echo "$REPO matches the standard."
        return 0
    fi
    if "$CHECK_ONLY"; then
        echo "${#LABELS[@]} settings differ from the standard."
        return 3
    fi
    if ! confirm "Change ${#LABELS[@]} settings on $REPO?"; then
        echo "Nothing was changed."
        return 0
    fi
    local status=0
    apply || status=1
    # The checks were chosen, so reading again doesn't ask
    CHECKS_GIVEN=true
    verify || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
