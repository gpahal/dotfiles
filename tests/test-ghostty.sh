#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions

# The ghostty step: config reload, Application Support overrides, the terminfo SSH logins read on
# both OSes, and Ubuntu's snap.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

terminfo="$SANDBOX/snap-terminfo" mac_terminfo="$SANDBOX/app-terminfo"
export DOTFILES_GHOSTTY_TERMINFO="$terminfo" DOTFILES_GHOSTTY_MAC_TERMINFO="$mac_terminfo"
echo "Ghostty.app's compiled entry" > "$mac_terminfo"
load_script ghostty/install.sh
as_os macos
config="$HOME/.config/ghostty/config.ghostty"

stub pkill
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    xterm-ghostty terminfo in ~/.terminfo"
assert_idempotent main
assert_contains "$FIRST_OUTPUT" "Reloaded Ghostty config."
assert_eq "pkill -USR2 -x ghostty" "$FIRST_LOG" "commands run for a new config"
assert_not_contains "$RUN_OUTPUT" "Reload"
# An SSH login into the Mac reads Ghostty's terminfo from ~/.terminfo, in macOS's hex-named dir
assert_contains "$FIRST_OUTPUT" "Installed the xterm-ghostty terminfo in ~/.terminfo."
assert_eq "" "$(cmp "$mac_terminfo" "$HOME/.terminfo/78/xterm-ghostty" 2>&1)" "the Mac's terminfo copied"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         xterm-ghostty terminfo in ~/.terminfo"
assert_not_contains "$RUN_OUTPUT" "Ghostty snap installed"

# Without Ghostty.app, the step copies the config, then fails
mv "$mac_terminfo" "$SANDBOX/saved-terminfo"
rm -r "$HOME/.terminfo" "$HOME/.config/ghostty"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "No xterm-ghostty terminfo at $mac_terminfo. Install Ghostty with bash setup.sh homebrew"
[ -e "$HOME/.config/ghostty/config.ghostty" ] || fail "the config wasn't copied without Ghostty.app"
[ ! -e "$HOME/.terminfo" ] || fail "$HOME/.terminfo made without Ghostty.app's terminfo"
mv "$SANDBOX/saved-terminfo" "$mac_terminfo"

support="$HOME/Library/Application Support/com.mitchellh.ghostty"
mkdir -p "$support"
run status
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty" "Ghostty status with no other config"

# A keybind overrides only the same trigger
printf 'keybind = super+shift+equal=increase_font_size:1\nfont-size = 20\n' > "$support/config"
printf 'keybind = super+k=clear_screen\nwindow-save-state = always\n' > "$support/config.ghostty"
run status
assert_contains "$RUN_OUTPUT" "missing    ~/Library/Application Support/com.mitchellh.ghostty/config: Ghostty loads it after config.ghostty, so it overrides the repo's font-size, keybind super+shift+equal; merge it into the repo's config or remove it"
assert_not_contains "$RUN_OUTPUT" "com.mitchellh.ghostty/config.ghostty" "a file that only adds settings"

stub snap 'exit 1'
as_os ubuntu

# A failed snap install fails the step after it copies the config. test-step-prereqs.sh covers
# snapd missing.
rm "$config"
answer yes
assert_exit 1 main
assert_file_contains "$STUB_LOG" "sudo snap install ghostty --classic"
[ -e "$config" ] || fail "the ghostty config wasn't copied after a failed snap install"

# Without the snap's terminfo, zsh over SSH from Ghostty can't move the cursor
echo "compiled entry" > "$terminfo"
run status
assert_contains "$RUN_OUTPUT" "missing    xterm-ghostty terminfo in ~/.terminfo"

# A declined snap install leaves the terminfo, which comes from the snap
answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install Ghostty from its snap"
[ ! -e "$HOME/.terminfo" ] || fail "terminfo copied with the snap declined"

stub snap
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installed the xterm-ghostty terminfo in ~/.terminfo."
assert_eq "" "$(cmp "$terminfo" "$HOME/.terminfo/x/xterm-ghostty" 2>&1)" "terminfo copied"
assert_not_contains "$(cat "$STUB_LOG")" "install" "commands run with the snap installed"

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Ghostty and its terminfo already installed."
run status
assert_contains "$RUN_OUTPUT" "ok         xterm-ghostty terminfo in ~/.terminfo"
test_done
