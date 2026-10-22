#!/bin/bash
set -euo pipefail

# Check the tools `just check` and `just test` run meet the minimum versions.
# Minimums are Ubuntu 26.04 apt's tested floors, not known requirements, except yq's.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/check.sh
source "$DOTFILES_DIR/scripts/lib/check.sh"

TOOLS="jq 1.8.1 jq --version
yq $YQ_MIN_VERSION yq --version
just 1.45 just --version
zsh 5.9 zsh --version
tmux 3.6 tmux -V
vim 9.1 vim --version
git 2.53 git --version"

while read -r tool minimum cmd; do
    if ! command -v "$tool" &>/dev/null; then
        fail "$tool isn't installed (needs at least $minimum)"
        continue
    fi
    # shellcheck disable=SC2086 # the command and its flag
    output="$($cmd 2>&1 | head -n 1 || true)"
    if [ "$tool" == yq ] && [[ "$output" != *mikefarah* ]]; then
        fail "yq isn't mikefarah's (https://github.com/mikefarah/yq), which the scripts need: $output"
        continue
    fi
    version="$(printf '%s\n' "$output" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1 || true)"
    if [ -z "$version" ]; then
        fail "Couldn't read $tool's version from: $output"
    elif version_at_least "$version" "$minimum"; then
        echo "$tool $version (at least $minimum)"
    else
        fail "$tool $version is older than $minimum"
    fi
done <<< "$TOOLS"
[ "$errors" -eq 0 ]
