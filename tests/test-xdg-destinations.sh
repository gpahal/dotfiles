#!/bin/bash
# The steps' functions call the OS checks this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# With XDG_CONFIG_HOME set, the lazygit config goes under it on both OSes, and the Ghostty and Zed
# configs go under it on Ubuntu. On macOS, Ghostty and Zed still use ~/.config. Status reads the
# same paths. A stub uname makes a step pick its Ubuntu paths, which it chooses when it loads.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export XDG_CONFIG_HOME="$SANDBOX/xdg"

# check <step> <os> <repo file> <installed path> <copy function>: copy the step's files, then
# check the file landed there and status reports it ok
check() {
    local step="$1" os="$2" src="$3" dest="$4" copy="$5"
    rm -rf "$XDG_CONFIG_HOME" "$HOME/.config" "$HOME/Library"
    if [ "$os" == ubuntu ]; then
        stub uname 'echo Linux'
    else
        stub uname 'echo Darwin'
    fi
    load_script "$step/install.sh"
    if [ "$os" == ubuntu ]; then
        is_macos() { false; }
        is_ubuntu() { true; }
    else
        is_macos() { true; }
        is_ubuntu() { false; }
    fi
    run "${step}_files" "$copy"
    assert_eq "" "$(cmp "$REPO_DIR/$src" "$dest" 2>&1)" "$step's config on $os"
    run "${step}_files" status_file
    assert_contains "$RUN_OUTPUT" "ok " "$step's status on $os"
    assert_not_contains "$RUN_OUTPUT" "missing" "$step's status on $os"
    rm -f "$STUB_DIR/uname"
}

check lazygit ubuntu lazygit/config.yml "$XDG_CONFIG_HOME/lazygit/config.yml" copy_file
check lazygit macos lazygit/config.yml "$XDG_CONFIG_HOME/lazygit/config.yml" copy_file
check ghostty ubuntu ghostty/config.ghostty "$XDG_CONFIG_HOME/ghostty/config.ghostty" copy_file
check ghostty macos ghostty/config.ghostty "$HOME/.config/ghostty/config.ghostty" copy_file
check zed ubuntu zed/settings.json "$XDG_CONFIG_HOME/zed/settings.json" copy_file
check zed macos zed/settings.json "$HOME/.config/zed/settings.json" copy_file
test_done
