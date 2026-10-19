#!/bin/bash
# The step's functions call the OS checks this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The tmux step installs tpm and each plugin at the commit tmux/plugins.lock pins, not at HEAD. A
# re-run changes nothing, a plugin at another commit is missing until a re-run moves it back, with
# no fetch when the checkout has the pin, and a plugin that fails to fetch fails the step after the
# others install. plugins.lock lists the plugins tmux.conf loads. Local repos stand in for GitHub.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"

# plugins.lock pins every plugin tmux.conf loads, tpm first, each to a full commit
assert_eq "$(sed -n "s/^set -g @plugin '\(.*\)'/\1/p" "$REPO_DIR/tmux/tmux.conf")" \
    "$(grep -v '^#' "$REPO_DIR/tmux/plugins.lock" | awk '{ print $1 }')" "plugins.lock's repos"
assert_eq "" "$(grep -v '^#' "$REPO_DIR/tmux/plugins.lock" | grep -vE '^[^ ]+/[^ ]+ [0-9a-f]{40}$' || true)" \
    "plugins.lock lines that aren't <owner>/<repo> <sha>"

fake_tmux_plugins
load_script tmux/install.sh
is_ubuntu() { false; }
is_macos() { true; }
stub tmux

# Print each plugin's checkout as "<name> <HEAD>"
installed() {
    local dir
    for dir in "$HOME/.tmux/plugins"/*; do
        echo "${dir##*/} $(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    done
}
pinned="$(grep -v '^#' "$DOTFILES_TMUX_PLUGINS_LOCK" | sed 's|^[^ ]*/||' | sort)"

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installed tmux plugin tmux-plugins/tpm at"
assert_eq "$pinned" "$(installed)" "the plugins' checkouts"
run status
assert_eq 0 "$RUN_STATUS" "status once installed"
short="$(awk '$1 == "tmux-plugins/tmux-yank" { print substr($2, 1, 7) }' "$DOTFILES_TMUX_PLUGINS_LOCK")"
assert_contains "$RUN_OUTPUT" "ok         tmux plugin tmux-plugins/tmux-yank at $short"

# A re-run changes nothing
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "tmux plugins already at their pinned commits"
assert_not_contains "$RUN_OUTPUT" "Installed"

# A plugin at another commit, as an older checkout or a bumped pin leaves it, is missing until a
# re-run moves it to its pin
git -C "$FAKE_PLUGIN_REMOTES/tmux-plugins/tmux-yank" rev-parse HEAD > "$SANDBOX/head"
git -C "$HOME/.tmux/plugins/tmux-yank" fetch -q "$FAKE_PLUGIN_REMOTES/tmux-plugins/tmux-yank"
git -C "$HOME/.tmux/plugins/tmux-yank" checkout -q --detach FETCH_HEAD
assert_eq "$(cat "$SANDBOX/head")" "$(git -C "$HOME/.tmux/plugins/tmux-yank" rev-parse HEAD)" "the moved checkout"
run status
assert_eq 3 "$RUN_STATUS" "status with a plugin at another commit"
assert_contains "$RUN_OUTPUT" "missing    tmux plugin tmux-plugins/tmux-yank at $short"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installed tmux plugin tmux-plugins/tmux-yank at $short"
assert_eq "$pinned" "$(installed)" "the checkouts after a re-run"

# Offline, a checkout that has its pin, as one moved from it does, goes back to it without a fetch.
# One that lacks its pin fails.
yank="$HOME/.tmux/plugins/tmux-yank"
git -C "$yank" checkout -q --detach "$(cat "$SANDBOX/head")"
mv "$FAKE_PLUGIN_REMOTES/tmux-plugins/tmux-yank" "$SANDBOX/yank"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installed tmux plugin tmux-plugins/tmux-yank at $short"
assert_eq "$pinned" "$(installed)" "the checkouts after an offline re-run"
rm -rf "$yank"
git init -q "$yank"
git -C "$yank" fetch -q --depth 1 "$SANDBOX/yank" "$(cat "$SANDBOX/head")"
git -C "$yank" checkout -q --detach FETCH_HEAD
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't install tmux plugin tmux-plugins/tmux-yank"
assert_eq "$(cat "$SANDBOX/head")" "$(git -C "$yank" rev-parse HEAD)" "a checkout without its pin, offline"
mv "$SANDBOX/yank" "$FAKE_PLUGIN_REMOTES/tmux-plugins/tmux-yank"

# A plain dir with files in it is left alone and fails the step; an empty one becomes the checkout
rm -rf "$yank"
mkdir -p "$yank"
echo mine > "$yank/README"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$yank isn't a git checkout, and isn't empty. Move it"
assert_eq mine "$(cat "$yank/README")" "a file in a plain plugin dir"
rm "$yank/README"
assert_exit 0 main
assert_eq "$pinned" "$(installed)" "the checkouts after an empty plugin dir"

# A plugin that can't be fetched fails the step, and the others still install
rm -rf "$HOME/.tmux/plugins"
mv "$FAKE_PLUGIN_REMOTES/tmux-plugins/tmux-yank" "$SANDBOX/yank"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't install tmux plugin tmux-plugins/tmux-yank"
assert_eq "$(grep -v tmux-yank <<< "$pinned")" "$(installed | grep -v tmux-yank)" "the checkouts with tmux-yank unreachable"
test_done
