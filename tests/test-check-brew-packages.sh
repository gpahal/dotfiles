#!/bin/bash
set -euo pipefail

# scripts/check-brew-packages.sh passes when brew knows every package and every formula Ubuntu
# gets has a Linux bottle, and fails, naming the package, on an unknown, deprecated, or disabled
# one, or a formula outside `if OS.mac?` with no x86_64_linux or all bottle. brew and curl answer
# from fixtures: brew from $SANDBOX/brew/<name>, and curl, formulae.brew.sh's API, from
# $SANDBOX/api/<name>.json.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"

check="$REPO_DIR/scripts/check-brew-packages.sh"
mkdir -p "$SANDBOX/brew" "$SANDBOX/api"

# brew info --json=v2 <--formula|--cask> <name>... fails when any name has no fixture
stub brew 'kind="$3"
shift 3
files=()
for name in "$@"; do
    [ -f "'"$SANDBOX"'/brew/$name" ] || { echo "Error: No available ${kind#--} with the name \"$name\"." >&2; exit 1; }
    files+=("'"$SANDBOX"'/brew/$name")
done
case "$kind" in --formula) key=formulae ;; *) key=casks ;; esac
jq -s --arg key "$key" "{(\$key): .}" "${files[@]}"'
stub curl 'url="${!#}"
cat "'"$SANDBOX"'/api/${url##*/}" 2>/dev/null || exit 22'

# package <formula|cask> <name> [jq filter], with the filter applied to a package in good standing
package() {
    case "$1" in
        formula) jq -n --arg n "$2" "{name: \$n, deprecated: false, disabled: false} | ${3:-.}" ;;
        cask) jq -n --arg n "$2" "{token: \$n, deprecated: false, disabled: false} | ${3:-.}" ;;
    esac > "$SANDBOX/brew/$2"
}
# bottles <formula> <tag>...
bottles() {
    local name="$1"
    shift
    printf '%s\n' "$@" | jq -R . | jq -s '{bottle: {stable: {files: (map({(.): {}}) | add // {})}}}' \
        > "$SANDBOX/api/$name.json"
}

while read -r _ name; do
    name="${name//\"/}"
    package formula "$name"
    bottles "$name" arm64_tahoe x86_64_linux
done < <(grep -E '^[[:space:]]*brew "' "$REPO_DIR/homebrew/Brewfile")
# shellcheck disable=SC2016 # expanded by the inner bash
for name in $("$BASH" -c 'source "$1/homebrew/install.sh" && printf "%s\n" "${CASKS[@]}" "${UBUNTU_CASKS[@]}"' bash "$REPO_DIR"); do
    package cask "$name"
done

assert_exit 0 "$BASH" "$check"
assert_contains "$RUN_OUTPUT" "Every formula and cask the homebrew step installs exists"

# A Mac-only formula needs no Linux bottle, and a bottle for all platforms counts
bottles mas arm64_tahoe
bottles jq all
assert_exit 0 "$BASH" "$check"

# An unknown formula and cask, a deprecated formula, a disabled cask, and a formula Ubuntu gets
# with no Linux bottle
rm "$SANDBOX/brew/glow" "$SANDBOX/brew/zed"
package formula httpie '.deprecated = true | .deprecation_reason = "unmaintained"'
package cask raycast '.deprecated = true | .disabled = true | .disable_reason = "discontinued"'
bottles fd arm64_tahoe
assert_exit 1 "$BASH" "$check"
assert_contains "$RUN_OUTPUT" "brew has no formula named glow"
assert_contains "$RUN_OUTPUT" "brew has no cask named zed"
assert_contains "$RUN_OUTPUT" "The formula httpie is deprecated: unmaintained"
assert_contains "$RUN_OUTPUT" "The cask raycast is disabled: discontinued"
assert_contains "$RUN_OUTPUT" "The formula fd has no x86_64_linux bottle"
assert_not_contains "$RUN_OUTPUT" "raycast is deprecated"
assert_not_contains "$RUN_OUTPUT" "formula mas"
assert_not_contains "$RUN_OUTPUT" "formula jq"
assert_not_contains "$RUN_OUTPUT" "Every formula"

# formulae.brew.sh not answering for a formula
package formula glow
package cask zed
package formula httpie
package cask raycast
bottles fd x86_64_linux
rm "$SANDBOX/api/bat.json"
assert_exit 1 "$BASH" "$check"
assert_contains "$RUN_OUTPUT" "Couldn't read the formula bat from https://formulae.brew.sh/api/formula"
test_done
