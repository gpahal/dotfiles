#!/bin/bash
set -euo pipefail

# Check that the packages the homebrew step installs still exist: brew must know each formula in
# homebrew/Brewfile and each cask in homebrew/install.sh's CASKS and UBUNTU_CASKS, and none may be
# deprecated or disabled. Each formula outside the Brewfile's `if OS.mac?` blocks must also have an
# x86_64_linux bottle, or one for all platforms, so Ubuntu doesn't build it from source. brew info
# lists only the bottles for the platform it runs on, so those come from formulae.brew.sh's API.
# Needs brew, jq, curl, and the network. CI runs it on macOS (.github/workflows/check.yml); `just
# check` doesn't.

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/brew.sh
source "$REPO_DIR/scripts/lib/brew.sh"
FORMULA_API=https://formulae.brew.sh/api/formula
errors=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "$1" >&2
    errors=$((errors + 1))
}

for cmd in brew jq curl; do
    command -v "$cmd" &>/dev/null || { echo "check-brew-packages.sh needs $cmd" >&2; exit 1; }
done

brewfile_formulae "$REPO_DIR/homebrew/Brewfile" > "$tmp/formulae"
for list in CASKS UBUNTU_CASKS; do
    cask_list "$REPO_DIR/homebrew/install.sh" "$list"
done | sort -u > "$tmp/casks"
[ -s "$tmp/formulae" ] && [ -s "$tmp/casks" ] ||
    { echo "Couldn't read the formulae from homebrew/Brewfile or the casks from homebrew/install.sh" >&2; exit 1; }

# brew_info <--formula|--cask> <name>...: print brew info's JSON for the names. One unknown name
# fails the whole call, so then each name is looked up alone, and an unknown one fails the check.
brew_info() {
    local kind="$1" name known=()
    shift
    brew info --json=v2 "$kind" "$@" 2>/dev/null && return
    for name in "$@"; do
        if brew info --json=v2 "$kind" "$name" &>/dev/null; then
            known+=("$name")
        else
            fail "brew has no ${kind#--} named $name"
        fi
    done
    [ ${#known[@]} -eq 0 ] || brew info --json=v2 "$kind" "${known[@]}"
}

# shellcheck disable=SC2046 # one name per word
brew_info --formula $(cut -d' ' -f1 "$tmp/formulae") > "$tmp/formulae.json"
# shellcheck disable=SC2046
brew_info --cask $(cat "$tmp/casks") > "$tmp/casks.json"

# A disabled package is deprecated too, so disabled comes first
while IFS= read -r line; do
    fail "$line"
done < <(jq -rs '.[] | ((.formulae // [] | .[] | . + {kind: "formula", id: .name}),
        (.casks // [] | .[] | . + {kind: "cask", id: .token}))
    | if .disabled then "The \(.kind) \(.id) is disabled: \(.disable_reason // "no reason given")"
      elif .deprecated then "The \(.kind) \(.id) is deprecated: \(.deprecation_reason // "no reason given")"
      else empty end' "$tmp/formulae.json" "$tmp/casks.json")

# The Linux bottles of the formulae Ubuntu gets, by the names brew resolved
jq -r '.formulae[].name' "$tmp/formulae.json" > "$tmp/known"
while read -r name os; do
    if [ "$os" != any ] || ! grep -qxF -- "$name" "$tmp/known"; then
        continue
    fi
    if ! tags="$(curl -fsSL --retry 3 "$FORMULA_API/$name.json" | jq -r '.bottle.stable.files // {} | keys[]')"; then
        fail "Couldn't read the formula $name from $FORMULA_API"
    elif ! printf '%s\n' "$tags" | grep -qxE 'x86_64_linux|all'; then
        fail "The formula $name has no x86_64_linux bottle, so Ubuntu would build it. Move it into the Brewfile's if OS.mac? block, or drop it."
    fi
done < "$tmp/formulae"

if [ "$errors" -eq 0 ]; then
    echo "Every formula and cask the homebrew step installs exists, and every formula Ubuntu gets has a Linux bottle."
fi
[ "$errors" -eq 0 ]
