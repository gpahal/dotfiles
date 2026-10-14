#!/bin/bash
# The steps' functions call the OS checks this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On macOS, Ghostty loads the files in ~/Library/Application Support/com.mitchellh.ghostty after
# the repo's config.ghostty. The ghostty step's status flags one that sets something the repo's
# config sets, and says nothing of one that only adds settings or sets nothing. Ubuntu has no
# Application Support.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
stub snap 'exit 1'
# ghostty_status <macos|ubuntu>: run the ghostty step's status as on that OS
ghostty_status() {
    load_script ghostty/install.sh
    if [ "$1" == macos ]; then
        is_macos() { true; }
        is_ubuntu() { false; }
    else
        is_macos() { false; }
        is_ubuntu() { true; }
    fi
    run status
}
support="$HOME/Library/Application Support/com.mitchellh.ghostty"
mkdir -p "$support"
ghostty_status macos
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty" "Ghostty status with no other config"

# Empty files and comments set nothing
: > "$support/config"
printf '# comment\n' > "$support/config.ghostty"
ghostty_status macos
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty" "Ghostty status with empty Application Support files"

# A setting the repo's config has overrides it. A keybind overrides only the same trigger.
printf 'keybind = super+shift+equal=increase_font_size:1\nfont-size = 20\n' > "$support/config"
printf 'keybind = super+k=clear_screen\nwindow-save-state = always\n' > "$support/config.ghostty"
ghostty_status macos
assert_contains "$RUN_OUTPUT" "missing    ~/Library/Application Support/com.mitchellh.ghostty/config: Ghostty loads it after config.ghostty, so it overrides the repo's font-size, keybind super+shift+equal; merge it into the repo's config or remove it"
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty/config.ghostty" "a file that only adds settings"
ghostty_status ubuntu
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty"
test_done
