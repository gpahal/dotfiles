#!/bin/bash

# zsh/command-not-found.zsh. brew is asked only on a terminal, so a pipe never waits on its
# auto-update.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v zsh &>/dev/null || skip "zsh isn't installed"

stub brew '[ "$*" == "which-formula --explain brewtool" ] && echo "brewtool: brew install brewtool"; true'
APT_CNF="$SANDBOX/command-not-found"
printf '#!/bin/sh\necho "apt: $2" >&2\nexit 127\n' > "$APT_CNF"
chmod +x "$APT_CNF"

# missing <OSTYPE> <apt command-not-found path> <command>
MISSING='OSTYPE=$1; source "$2/zsh/command-not-found.zsh"; _apt_command_not_found=$3; $4; print "status $?"'
missing() {
    zsh -f -c "$MISSING" zsh "$1" "$REPO_DIR" "$2" "$3" 2>&1
}
missing_in_terminal() {
    in_terminal zsh -f -c "$MISSING" zsh "$1" "$REPO_DIR" "$2" "$3"
}

assert_eq "apt: brewtool
status 127" "$(missing linux-gnu "$APT_CNF" brewtool)" "a command brew knows, piped, on Ubuntu"
assert_file_not_contains "$STUB_LOG" "brew"
if in_terminal_available; then
    assert_eq "brewtool: brew install brewtool
status 127" "$(missing_in_terminal linux-gnu "$APT_CNF" brewtool)" "a command brew knows, on Ubuntu"
    assert_eq "apt: apttool
status 127" "$(missing_in_terminal linux-gnu "$APT_CNF" apttool)" "a command brew doesn't know, on Ubuntu"
else
    skip_rest "brew's suggestion in a terminal: script isn't installed"
fi
assert_eq "zsh: command not found: apttool
status 127" "$(missing linux-gnu "$SANDBOX/none" apttool)" "without apt's command-not-found"
test_done
