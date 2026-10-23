#!/bin/bash
set -euo pipefail

# Check the t3-code step's keys appear in T3 Code's settings schemas at the latest release or a given tag.
# Name-only smoke test.

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

# Reads check's schemas
in_schemas() {
    grep -qE "(^|[^A-Za-z0-9_\$])\"?$1\"?\??:" "${schemas[@]}"
}

# check <what> <filter> <schema file>...
check() {
    local what="$1" filter="$2" schemas
    shift 2
    schemas=("$@")
    # shellcheck disable=SC2046 # a list of keys
    missing_names "for $what" key dotfilesNoSuchT3Setting in_schemas $(keys_of "$filter")
    if [ -n "$MISSING" ]; then
        fail "T3 Code $tag's schema lacks these $what keys the t3-code step writes:$MISSING"
    else
        echo "  $what: every key is in the schema"
    fi
}

check "server settings" "$(t3_code_server_filter)" "$tmp/settings.ts" "$tmp/project.ts"
check "client settings" "$T3_CODE_CLIENT_FILTER" "$tmp/settings.ts"

finish_checks
