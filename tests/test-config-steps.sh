#!/bin/bash
set -euo pipefail

# The config steps run through setup.sh twice in a sandbox: the second run changes nothing, and
# --status then reports everything set up apart from the GitHub login and the settings that depend
# on it.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

STEPS=(git lazygit ssh zsh vim tmux zed hammerspoon editorconfig)
command -v git &>/dev/null || skip "git isn't installed"
# The tmux step needs tmux installed, though nothing here runs it
if ! command -v tmux &>/dev/null; then
    skip_rest "the tmux step: tmux isn't installed"
    STEPS=(git lazygit ssh zsh vim zed hammerspoon editorconfig)
fi

# A brew on PATH stops lib/common.sh from putting Homebrew's directories before the stubs
stub brew 'exit 1'
# Not logged in to GitHub, so the git step defers login without a terminal
stub gh 'exit 1'
stub_login_shell_zsh
# The ssh step's LaunchAgent counts as loaded: a temp HOME mustn't load it into your session
stub launchctl '[ "$1" == print ]'
# On Ubuntu, continuum's unit that starts tmux at boot counts as enabled: tests/test-tmux-boot.sh
# covers enabling it
stub systemctl '[ "$*" == "--user is-enabled --quiet tmux.service" ]'

fake_tmux_plugins

assert_exit 0 bash "$REPO_DIR/setup.sh" "${STEPS[@]}"
assert_contains "$RUN_OUTPUT" "Copied"

# The second run copies and adds nothing
assert_exit 0 bash "$REPO_DIR/setup.sh" "${STEPS[@]}"
changes="$(printf '%s\n' "$RUN_OUTPUT" | grep -E 'Copied|Added|Installed' || true)"
assert_eq "" "$changes" "the second run's Copied, Added, and Installed lines"
for cmd in brew chsh sudo "launchctl bootstrap"; do
    assert_file_not_contains "$STUB_LOG" "$cmd"
done

# Every status item is ok, skipped, or unverified, apart from the GitHub login and the credential
# helper, which gh sets up after you log in, and on Ubuntu the HTTPS rewrite, which needs the
# helper. That's why status exits 3.
assert_exit 3 bash "$REPO_DIR/setup.sh" --status "${STEPS[@]}"
items="$(printf '%s\n' "$RUN_OUTPUT" | grep -E '^  [a-z]+ ' | grep -vE '^  (ok|skipped|unverified) ' || true)"
expected="  missing    Logged in to GitHub with gh
  missing    git uses gh for GitHub credentials"
if [ "$(uname -s)" != Darwin ]; then
    expected+="
  missing    GitHub SSH remotes go over HTTPS, through gh's credential helper (a re-run after gh auth login and gh auth setup-git adds it)"
fi
assert_eq "$expected" "$items" "status items that need attention"

# Zed's settings, which Zed itself edits, are replaced like any other config: no question, even
# without a terminal, and no backup
zed_settings="$HOME/.config/zed/settings.json"
printf '{"edited in Zed": true}\n' > "$zed_settings"
assert_exit 3 bash "$REPO_DIR/setup.sh" --status zed
assert_contains "$RUN_OUTPUT" "settings.json differs from the repo's zed/settings.json"
assert_exit 0 bash "$REPO_DIR/setup.sh" zed
assert_eq "" "$(cmp "$REPO_DIR/zed/settings.json" "$zed_settings" 2>&1)" "Zed's settings after an edit"
assert_eq "keymap.json settings.json " "$(/bin/ls -A "$(dirname "$zed_settings")" | tr '\n' ' ')" "Zed's config files"

# Config paths honor XDG_CONFIG_HOME on Linux; Ghostty and Zed use ~/.config on macOS.
export XDG_CONFIG_HOME="$SANDBOX/xdg"

# check_destination <step> <os> <repo file> <installed path> <copy function>: copy the step's files, then
# check the file landed there and status reports it ok
check_destination() {
    local step="$1" os="$2" src="$3" dest="$4" copy="$5"
    rm -rf "$XDG_CONFIG_HOME" "$HOME/.config" "$HOME/Library"
    if [ "$os" == ubuntu ]; then
        stub uname 'echo Linux'
    else
        stub uname 'echo Darwin'
    fi
    load_script "$step/install.sh"
    if [ "$os" == ubuntu ]; then
        as_os ubuntu
    else
        as_os macos
    fi
    run "${step}_files" "$copy"
    assert_eq "" "$(cmp "$REPO_DIR/$src" "$dest" 2>&1)" "$step's config on $os"
    run "${step}_files" status_file
    assert_contains "$RUN_OUTPUT" "ok " "$step's status on $os"
    assert_not_contains "$RUN_OUTPUT" "missing" "$step's status on $os"
    rm -f "$STUB_DIR/uname"
}

check_destination lazygit ubuntu lazygit/config.yml "$XDG_CONFIG_HOME/lazygit/config.yml" copy_file
check_destination lazygit macos lazygit/config.yml "$XDG_CONFIG_HOME/lazygit/config.yml" copy_file
check_destination ghostty ubuntu ghostty/config.ghostty "$XDG_CONFIG_HOME/ghostty/config.ghostty" copy_file
check_destination ghostty macos ghostty/config.ghostty "$HOME/.config/ghostty/config.ghostty" copy_file
check_destination zed ubuntu zed/settings.json "$XDG_CONFIG_HOME/zed/settings.json" copy_file
check_destination zed macos zed/settings.json "$HOME/.config/zed/settings.json" copy_file
test_done
