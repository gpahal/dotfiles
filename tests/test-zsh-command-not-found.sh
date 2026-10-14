#!/bin/bash
set -euo pipefail

# zsh/command-not-found.zsh: on Ubuntu, an unknown command gets brew's suggestion when brew has
# one, and otherwise apt's command-not-found's, or zsh's own message without either. brew is asked
# only when stdout is a terminal, so a pipe or an agent's shell never waits on its auto-update.
# On macOS it sources Homebrew's handler. Every case exits 127.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"

# brew suggests a formula for brewtool and nothing for anything else
stub brew '[ "$*" == "which-formula --explain brewtool" ] && echo "brewtool: brew install brewtool"; true'
APT_CNF="$SANDBOX/command-not-found"
printf '#!/bin/sh\necho "apt: $2" >&2\nexit 127\n' > "$APT_CNF"
chmod +x "$APT_CNF"

# Run an unknown command in zsh with the handler loaded as on the given OS, and apt's
# command-not-found at the given path, printing its output and exit status
# shellcheck disable=SC2016 # expanded by zsh
MISSING='OSTYPE=$1; source "$2/zsh/command-not-found.zsh"; _apt_command_not_found=$3; $4; print "status $?"'
missing() {
    zsh -f -c "$MISSING" zsh "$1" "$REPO_DIR" "$2" "$3" 2>&1
}
# The same with stdout on a terminal, which script gives it. Both scripts end lines with \r\n,
# and macOS's echoes the ^D it sends when stdin ends.
missing_in_terminal() {
    if [ "$(uname -s)" == Darwin ]; then
        script -q /dev/null zsh -f -c "$MISSING" zsh "$1" "$REPO_DIR" "$2" "$3"
    else
        script -qec "$(printf '%q ' zsh -f -c "$MISSING" zsh "$1" "$REPO_DIR" "$2" "$3")" /dev/null
    fi < /dev/null | tr -d '\r\b' | sed 's/^^D//'
}

# Piped, brew isn't asked
assert_eq "apt: brewtool
status 127" "$(missing linux-gnu "$APT_CNF" brewtool)" "a command brew knows, piped, on Ubuntu"
assert_file_not_contains "$STUB_LOG" "brew"
if command -v script &>/dev/null; then
    assert_eq "brewtool: brew install brewtool
status 127" "$(missing_in_terminal linux-gnu "$APT_CNF" brewtool)" "a command brew knows, on Ubuntu"
    assert_eq "apt: apttool
status 127" "$(missing_in_terminal linux-gnu "$APT_CNF" apttool)" "a command brew doesn't know, on Ubuntu"
    hide brew
    assert_eq "apt: brewtool
status 127" "$(missing_in_terminal linux-gnu "$APT_CNF" brewtool)" "without brew, on Ubuntu"
else
    skip_rest "brew's suggestion in a terminal: script isn't installed"
    hide brew
fi
assert_eq "zsh: command not found: apttool
status 127" "$(missing linux-gnu "$SANDBOX/none" apttool)" "without apt's command-not-found"

# macOS sources Homebrew's handler from HOMEBREW_REPOSITORY
export HOMEBREW_REPOSITORY="$SANDBOX/brew"
mkdir -p "$HOMEBREW_REPOSITORY/Library/Homebrew/command-not-found"
echo 'command_not_found_handler() { print "homebrew: $1"; return 127; }' \
    > "$HOMEBREW_REPOSITORY/Library/Homebrew/command-not-found/handler.sh"
assert_eq "homebrew: anytool
status 127" "$(missing darwin25.0 "$APT_CNF" anytool)" "a missing command on macOS"
test_done
