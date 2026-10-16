#!/bin/bash
set -euo pipefail

# Check that every key the t3-code step writes exists in T3 Code's settings schemas, at the
# release the step installs: the latest, or the tag given as the only argument (e.g. v0.1.0).
# T3 Code ignores a key it doesn't know, so a renamed or dropped setting would otherwise go
# unnoticed. The keys come from the step's jq filters: each field after a "." and each object
# key. They're checked as properties in these files:
# - server settings (settings.json): packages/contracts/src/settings.ts, and for the project script
#   actions project.ts, or orchestration.ts, which held them up to 0.0.45. Either may be missing.
# - client settings (client-settings.json): packages/contracts/src/settings.ts
# A made-up key must be missing, so the search can fail. It's a smoke test of key names: a name
# found anywhere in the files passes, so it doesn't check which object a key sits in, and it
# doesn't check values against the schemas' allowed literals. It also warns, without failing, when
# the step writes a key's default (withDecodingDefault(Effect.succeed(<value>))): T3 Code drops
# such a key, so the step never settles. Needs curl and the network. CI runs it in the ai-settings
# job (.github/workflows/check.yml); `just check` doesn't.

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM=pingdotgg/t3code

if [ $# -gt 1 ]; then
    echo "usage: check-t3-settings.sh [<tag>]" >&2
    exit 2
fi
command -v curl &>/dev/null || { echo "curl isn't installed" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# GITHUB_TOKEN, which CI sets, lifts the API's rate limit for unauthenticated calls
download() {
    local auth=()
    [ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL --proto '=https' --retry 3 --retry-delay 2 ${auth[@]+"${auth[@]}"} -o "$2" "$1"
}

tag="${1:-}"
if [ -z "$tag" ]; then
    download "https://api.github.com/repos/$UPSTREAM/releases/latest" "$tmp/release.json"
    tag="$(sed -nE 's/^ *"tag_name": *"([^"]+)".*/\1/p' "$tmp/release.json" | head -1)"
    [ -n "$tag" ] || { echo "Couldn't read the latest T3 Code release's tag" >&2; exit 1; }
fi
echo "T3 Code $tag"
# get <path> [optional]: download a file at the tag, failing when it's missing unless it's optional
get() {
    download "https://raw.githubusercontent.com/$UPSTREAM/$tag/$1" "$tmp/${1##*/}" 2>/dev/null && return 0
    rm -f "$tmp/${1##*/}"
    [ -z "${2:-}" ] && { echo "Couldn't download $1 at $tag. If T3 Code moved it, update this script." >&2; exit 1; }
    return 0
}
get packages/contracts/src/settings.ts
get packages/contracts/src/project.ts optional
get packages/contracts/src/orchestration.ts optional
project_files=()
for file in "$tmp/project.ts" "$tmp/orchestration.ts"; do
    [ ! -f "$file" ] || project_files+=("$file")
done
if [ "${#project_files[@]}" -eq 0 ]; then
    echo "Couldn't download project.ts or orchestration.ts at $tag. If T3 Code moved the project script schema, update this script." >&2
    exit 1
fi

# shellcheck source=../ai_tools/t3-code/install.sh
source "$REPO_DIR/ai_tools/t3-code/install.sh"

errors=0
fail() {
    echo "FAIL: $1" >&2
    errors=$((errors + 1))
}

# Print the keys a jq filter reads or writes, one per line: .name, and "name": in an object
keys_of() {
    printf '%s\n' "$1" | grep -oE '\.[a-zA-Z_][a-zA-Z0-9_]*|"[a-zA-Z_][a-zA-Z0-9_]*":' |
        sed -E 's/^\.//; s/^"//; s/":$//' | sort -u
}

# check <what> <filter> <schema file>...: each key of the filter is a property in one of the
# files, as `key:`, `key?:`, or `"key":`
check() {
    local what="$1" filter="$2" key missing=""
    shift 2
    for key in $(keys_of "$filter") dotfilesNoSuchT3Setting; do
        grep -qE "(^|[^A-Za-z0-9_\$])\"?$key\"?\??:" "$@" || missing="$missing $key"
    done
    case "$missing" in
        *" dotfilesNoSuchT3Setting") missing="${missing% dotfilesNoSuchT3Setting}" ;;
        *) fail "the search for $what found a made-up key, so it can't check the real ones" ;;
    esac
    if [ -n "$missing" ]; then
        fail "T3 Code $tag's schema lacks these $what keys the t3-code step writes:$missing"
    else
        echo "  $what: every key is in the schema"
    fi
}

# Print each scalar value a jq filter writes, one "<key> <value>" per line, from `.key = <value>`
assignments_of() {
    printf '%s\n' "$1" | grep -oE '\.[a-zA-Z_][a-zA-Z0-9_]* = ("[^"]*"|true|false|null|-?[0-9]+)' |
        sed -E 's/^\.//; s/ = / /'
}

# schema_defaults <key> <schema file>...: print each default the files give a key, the argument of
# a withDecodingDefault(Effect.succeed(...)) in the 3 lines from `key:`, before the next key, with
# any " as const" dropped. A constant's name is printed as is.
schema_defaults() {
    local key="$1"
    shift
    awk -v key="$key" '
        $0 ~ "^[[:space:]]*\"?" key "\"?[?]?:" { n = 3 }
        n > 0 && $0 !~ "^[[:space:]]*\"?" key "\"?[?]?:" && $0 ~ /^[[:space:]]*"?[A-Za-z_][A-Za-z0-9_]*"?[?]?:/ { n = 0 }
        n > 0 {
            n--
            if (match($0, /withDecodingDefault\(Effect\.succeed\(/)) {
                value = substr($0, RSTART + RLENGTH)
                sub(/\)\).*$/, "", value)
                sub(/ as const$/, "", value)
                print value
                n = 0
            }
        }' "$@"
}

# defaults_check <what> <filter> <schema file>...: warn about each value the filter writes that's
# its key's default
defaults_check() {
    local what="$1" filter="$2" key value default found=false
    shift 2
    while read -r key value; do
        while IFS= read -r default; do
            # A constant: look up its value in the files
            if [[ "$default" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                default="$(sed -nE "s/^(export )?const $default(: [^=]+)? = (.*);\$/\3/p" "$@" | head -1)"
            fi
            if [ -n "$default" ] && [ "$default" == "$value" ]; then
                warn "the t3-code step writes $what $key = $value, T3 Code $tag's default, which it drops, so the step never settles"
                found=true
            fi
        done < <(schema_defaults "$key" "$@")
    done < <(assignments_of "$filter")
    "$found" || echo "  $what: no value is its key's default"
}

warnings=0
warn() {
    echo "WARNING: $1" >&2
    # An annotation on the CI run
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning::$1"
    warnings=$((warnings + 1))
}

check "server settings" "$T3_CODE_SERVER_FILTER" "$tmp/settings.ts" "${project_files[@]}"
check "client settings" "$T3_CODE_CLIENT_FILTER" "$tmp/settings.ts"
defaults_check "server settings" "$T3_CODE_SERVER_FILTER" "$tmp/settings.ts" "${project_files[@]}"
defaults_check "client settings" "$T3_CODE_CLIENT_FILTER" "$tmp/settings.ts"

if [ "$errors" -gt 0 ]; then
    echo "$errors check(s) failed" >&2
    exit 1
fi
if [ "$warnings" -gt 0 ]; then
    echo "All checks passed, with $warnings warning(s)"
else
    echo "All checks passed"
fi
