#!/bin/bash
set -euo pipefail

# Check the tools `just check` and `just test` run meet the minimum versions.
# Minimums are Ubuntu 26.04 apt's tested floors, not known requirements, except yq's.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

TOOLS="jq 1.8.1 jq --version
yq $YQ_MIN_VERSION yq --version
just 1.45 just --version
zsh 5.9 zsh --version
tmux 3.6 tmux -V
vim 9.1 vim --version
git 2.53 git --version"

errors=0
while read -r tool minimum cmd; do
    if ! command -v "$tool" &>/dev/null; then
        echo "$tool isn't installed (needs at least $minimum)" >&2
        errors=$((errors + 1))
        continue
    fi
    # shellcheck disable=SC2086 # the command and its flag
    output="$($cmd 2>&1 | head -n 1 || true)"
    if [ "$tool" == yq ] && [[ "$output" != *mikefarah* ]]; then
        echo "yq isn't mikefarah's (https://github.com/mikefarah/yq), which the scripts need: $output" >&2
        errors=$((errors + 1))
        continue
    fi
    version="$(printf '%s\n' "$output" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1 || true)"
    if [ -z "$version" ]; then
        echo "Couldn't read $tool's version from: $output" >&2
        errors=$((errors + 1))
    elif version_at_least "$version" "$minimum"; then
        echo "$tool $version (at least $minimum)"
    else
        echo "$tool $version is older than $minimum" >&2
        errors=$((errors + 1))
    fi
done <<< "$TOOLS"
[ "$errors" -eq 0 ]
