#!/bin/bash
set -euo pipefail

# Check the t3-code step's keys appear in T3 Code's settings schemas at the latest release or a given tag.
# Name-only smoke test. Warns when the step writes a default, which T3 Code drops, so the step never settles.

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM=pingdotgg/t3code

if [ $# -gt 1 ]; then
    echo "usage: check-t3-settings.sh [<tag>]" >&2
    exit 2
fi
command -v curl &>/dev/null || { echo "curl isn't installed" >&2; exit 1; }

# shellcheck source=lib/check.sh
source "$REPO_DIR/scripts/lib/check.sh"
make_tmp

# GITHUB_TOKEN lifts CI's API rate limit; the header goes through stdin, since any local user can
# read a command line.
download() {
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --proto '=https' --retry 3 --retry-delay 2 -o "$2" "$1"
    else
        printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" |
            curl -fsSL --proto '=https' --retry 3 --retry-delay 2 -H @- -o "$2" "$1"
    fi
}

tag="${1:-}"
if [ -z "$tag" ]; then
    download "https://api.github.com/repos/$UPSTREAM/releases/latest" "$tmp/release.json"
    tag="$(sed -nE 's/^ *"tag_name": *"([^"]+)".*/\1/p' "$tmp/release.json" | head -1)"
    [ -n "$tag" ] || { echo "Couldn't read the latest T3 Code release's tag" >&2; exit 1; }
fi
echo "T3 Code $tag"
get() {
    download "https://raw.githubusercontent.com/$UPSTREAM/$tag/$1" "$tmp/${1##*/}" 2>/dev/null && return 0
    echo "Couldn't download $1 at $tag. If T3 Code moved it, update this script." >&2
    exit 1
}
get packages/contracts/src/settings.ts
get packages/contracts/src/project.ts

# shellcheck source=../ai_tools/t3-code/install.sh
source "$REPO_DIR/ai_tools/t3-code/install.sh"

# Strip jq comments first, so "e.g." can't yield a key g.
keys_of() {
    printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$/\1/' | grep -oE '\.[a-zA-Z_][a-zA-Z0-9_]*|"[a-zA-Z_][a-zA-Z0-9_]*":' |
        sed -E 's/^\.//; s/^"//; s/":$//' | sort -u
}

# check <what> <filter> <schema file>...; a made-up key must be missing, so the search can fail.
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

assignments_of() {
    printf '%s\n' "$1" | grep -oE '\.[a-zA-Z_][a-zA-Z0-9_]* = ("[^"]*"|true|false|null|-?[0-9]+)' |
        sed -E 's/^\.//; s/ = / /'
}

# Print a key's withDecodingDefault(Effect.succeed(...)) argument found within 3 lines of `key:`.
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

defaults_check() {
    local what="$1" filter="$2" key value default found=false
    shift 2
    while read -r key value; do
        while IFS= read -r default; do
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
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning::$1"
    warnings=$((warnings + 1))
}

check "server settings" "$(t3_code_server_filter)" "$tmp/settings.ts" "$tmp/project.ts"
check "client settings" "$T3_CODE_CLIENT_FILTER" "$tmp/settings.ts"
defaults_check "server settings" "$(t3_code_server_filter)" "$tmp/settings.ts" "$tmp/project.ts"
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
