#!/bin/bash
set -euo pipefail

# The config-only steps through setup.sh: apply, a second run changing nothing, status, and where
# each OS puts their configs.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

STEPS=(git lazygit ssh zsh vim tmux zed hammerspoon editorconfig)
command -v git &>/dev/null || skip "git isn't installed"
if ! command -v tmux &>/dev/null; then
    skip_rest "the tmux step: tmux isn't installed"
    STEPS=(git lazygit ssh zsh vim zed hammerspoon editorconfig)
fi

# A brew on PATH stops lib/common.sh from putting Homebrew's dirs before the stubs
stub brew 'exit 1'
stub gh 'exit 1'
stub_login_shell_zsh
# A temp HOME mustn't load the LaunchAgent into your session
stub launchctl '[ "$1" == print ]'
# tests/test-tmux-boot.sh covers enabling continuum's unit
stub systemctl '[ "$*" == "--user is-enabled --quiet tmux.service" ]'

# Local repos stand in for GitHub; each plugin is pinned to its first commit, not HEAD
fake_tmux_plugins() {
    local repo sha remote n
    FAKE_PLUGIN_REMOTES="$SANDBOX/remotes"
    export DOTFILES_TMUX_PLUGINS_LOCK="$SANDBOX/plugins.lock"
    echo "# Test pins" > "$DOTFILES_TMUX_PLUGINS_LOCK"
    while read -r repo _; do
        remote="$FAKE_PLUGIN_REMOTES/$repo"
        git init -q "$remote"
        for n in 1 2; do
            echo "$repo $n" > "$remote/README"
            git -C "$remote" add README
            git_commit "$remote" -m "$n"
            [ "$n" -eq 2 ] || sha="$(git -C "$remote" rev-parse HEAD)"
        done
        echo "$repo $sha" >> "$DOTFILES_TMUX_PLUGINS_LOCK"
    done < <(awk '!/^#/ && NF' "$REPO_DIR/tmux/plugins.lock")
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$FAKE_PLUGIN_REMOTES/.insteadOf"
    export GIT_CONFIG_VALUE_0=https://github.com/
}
fake_tmux_plugins

assert_exit 0 bash "$REPO_DIR/setup.sh" "${STEPS[@]}"
assert_contains "$RUN_OUTPUT" "Copied"

assert_exit 0 bash "$REPO_DIR/setup.sh" "${STEPS[@]}"
changes="$(printf '%s\n' "$RUN_OUTPUT" | grep -E 'Copied|Added|Installed' || true)"
assert_eq "" "$changes" "the second run's Copied, Added, and Installed lines"
for cmd in brew chsh sudo "launchctl bootstrap"; do
    assert_file_not_contains "$STUB_LOG" "$cmd"
done

# gh sets up the credential helper (and Ubuntu's HTTPS rewrite) only after login
assert_exit 3 bash "$REPO_DIR/setup.sh" --status "${STEPS[@]}"
items="$(printf '%s\n' "$RUN_OUTPUT" | grep -E '^  [a-z]+ ' | grep -vE '^  (ok|skipped|unverified) ' || true)"
expected="  missing    Logged in to GitHub with gh
  missing    git uses gh for GitHub credentials"
if [ "$(uname -s)" != Darwin ]; then
    expected+="
  missing    GitHub SSH remotes go over HTTPS, through gh's credential helper (a re-run after gh auth login and gh auth setup-git adds it)"
fi
assert_eq "$expected" "$items" "status items that need attention"

# Ghostty and Zed ignore XDG_CONFIG_HOME on macOS
export XDG_CONFIG_HOME="$SANDBOX/xdg"

# Usage: check_destination <step> <os> <repo file> <installed path> <copy function>
check_destination() {
    local step="$1" os="$2" src="$3" dest="$4" copy="$5"
    rm -rf "$XDG_CONFIG_HOME" "$HOME/.config" "$HOME/Library"
    if [ "$os" == ubuntu ]; then
        stub_uname Linux
    else
        stub_uname Darwin
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
check_destination ghostty macos ghostty/config.ghostty "$HOME/.config/ghostty/config.ghostty" copy_file
check_destination zed macos zed/settings.json "$HOME/.config/zed/settings.json" copy_file
test_done
