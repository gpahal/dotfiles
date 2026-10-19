#!/bin/bash
set -euo pipefail

# scripts/check-brew-packages.sh, with brew and formulae.brew.sh stubbed, passes when brew knows
# every formula in homebrew/Brewfile and cask in homebrew/install.sh, none is deprecated or
# disabled, and every formula Ubuntu gets has a Linux bottle. It fails naming an unknown package,
# which it finds by asking for each alone, a deprecated or disabled one, and a formula outside the
# Brewfile's macOS block with no x86_64_linux or all bottle. A macOS-only formula's bottles aren't
# read.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
# shellcheck source=../scripts/lib/brew.sh
source "$REPO_DIR/scripts/lib/brew.sh"

# The packages the stubs treat specially, one per line in each file
for list in unknown deprecated disabled no-linux-bottle; do
    : > "$SANDBOX/$list"
done
# brew info --json=v2 --formula|--cask <name>...: fails when it's given an unknown name, as brew
# does, else prints each package, deprecated or disabled when its list says so
stub brew '[ "$1 $2" == "info --json=v2" ] || exit 1
kind="$3"
shift 3
dir="'"$SANDBOX"'"
for name; do
    ! grep -qxF -- "$name" "$dir/unknown" || exit 1
done
if [ "$kind" == --formula ]; then
    printf "{\"formulae\": ["
    id=name
else
    printf "{\"casks\": ["
    id=token
fi
sep=""
for name; do
    deprecated=false disabled=false
    ! grep -qxF -- "$name" "$dir/deprecated" || deprecated=true
    # brew marks a disabled package deprecated too
    ! grep -qxF -- "$name" "$dir/disabled" || disabled=true deprecated=true
    printf "%s{\"%s\": \"%s\", \"deprecated\": %s, \"deprecation_reason\": \"old\", \"disabled\": %s}" \
        "$sep" "$id" "$name" "$deprecated" "$disabled"
    sep=,
done
echo "]}"'
# formulae.brew.sh's JSON for a formula, with a Linux bottle unless no-linux-bottle lists it
stub curl 'name="${!#}"
name="${name##*/}"
name="${name%.json}"
if grep -qxF -- "$name" "'"$SANDBOX"'/no-linux-bottle"; then
    echo "{\"bottle\": {\"stable\": {\"files\": {\"arm64_tahoe\": {}}}}}"
else
    echo "{\"bottle\": {\"stable\": {\"files\": {\"arm64_tahoe\": {}, \"x86_64_linux\": {}}}}}"
fi'
check() {
    : > "$STUB_LOG"
    assert_exit "$1" "$BASH" "$REPO_DIR/scripts/check-brew-packages.sh"
}

# One formula Ubuntu gets, one only macOS gets, and one cask, from the repo's own lists
linux_formula="$(brewfile_formulae "$REPO_DIR/homebrew/Brewfile" | awk '$2 == "any" { print $1; exit }')"
mac_formula="$(brewfile_formulae "$REPO_DIR/homebrew/Brewfile" | awk '$2 == "mac" { print $1; exit }')"
cask="$(cask_list "$REPO_DIR/homebrew/install.sh" CASKS | head -n 1)"
[ -n "$linux_formula" ] && [ -n "$mac_formula" ] && [ -n "$cask" ] ||
    fail "couldn't read a formula for each OS and a cask from the homebrew step"

check 0
assert_contains "$RUN_OUTPUT" "Every formula and cask the homebrew step installs exists"
assert_file_contains "$STUB_LOG" "curl -fsSL --retry 3 https://formulae.brew.sh/api/formula/$linux_formula.json"
assert_file_not_contains "$STUB_LOG" "formula/$mac_formula.json"

# An unknown formula fails the call naming every formula, so each is asked alone: only it fails,
# and the others are still checked
echo "$mac_formula" > "$SANDBOX/unknown"
echo "$cask" > "$SANDBOX/deprecated"
echo "$linux_formula" > "$SANDBOX/no-linux-bottle"
check 1
assert_contains "$RUN_OUTPUT" "brew has no formula named $mac_formula"
assert_file_contains "$STUB_LOG" "brew info --json=v2 --formula $linux_formula"
assert_contains "$RUN_OUTPUT" "The cask $cask is deprecated: old"
assert_contains "$RUN_OUTPUT" "The formula $linux_formula has no x86_64_linux bottle"
assert_not_contains "$RUN_OUTPUT" "Every formula"

# A disabled package is reported as disabled, not also as deprecated
: > "$SANDBOX/unknown"
: > "$SANDBOX/no-linux-bottle"
echo "$cask" > "$SANDBOX/disabled"
check 1
assert_contains "$RUN_OUTPUT" "The cask $cask is disabled"
assert_not_contains "$RUN_OUTPUT" "is deprecated"

# formulae.brew.sh can't be reached
: > "$SANDBOX/deprecated"
: > "$SANDBOX/disabled"
stub curl 'exit 22'
check 1
assert_contains "$RUN_OUTPUT" "Couldn't read the formula $linux_formula from https://formulae.brew.sh/api/formula"

test_done
