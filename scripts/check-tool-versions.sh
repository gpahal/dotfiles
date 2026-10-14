#!/bin/bash
set -euo pipefail

# Check that the tools `just check` and `just test` run are at least the versions the repo
# declares. Each minimum is the tested floor, what Ubuntu 24.04's apt has, the oldest release CI
# runs, not a version known to be required: an older one may work, but nothing tests it. GitHub's
# Ubuntu runners ship a newer git than apt's, so CI doesn't test git's floor; the version this
# prints for each tool is what the run tested. yq's is a real requirement: the codex step rewrites
# config.toml with yq -o toml, whose encoder arrived in 4.52.1 and was fixed up to 4.54.1. CI
# pins shellcheck instead, since each release reports different warnings. The scripts themselves
# target /bin/bash 3.2. CI runs this first (.github/workflows/check.yml).

# tool, minimum, and the command that prints its version
TOOLS="jq 1.7.1 jq --version
yq 4.54.1 yq --version
just 1.21 just --version
zsh 5.9 zsh --version
tmux 3.4 tmux -V
vim 9.1 vim --version
git 2.43 git --version"

# version_at_least <version> <minimum>: compare dot-separated numbers, a missing part counting as 0
version_at_least() {
    local IFS=. i have want
    read -ra have <<< "$1"
    read -ra want <<< "$2"
    for ((i = 0; i < ${#want[@]} || i < ${#have[@]}; i++)); do
        [ "${have[i]:-0}" -eq "${want[i]:-0}" ] && continue
        [ "${have[i]:-0}" -gt "${want[i]:-0}" ]
        return
    done
}

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
