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
test_done
