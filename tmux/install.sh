#!/bin/bash
set -euo pipefail

# Copy the tmux config and tmux-sessionizer, and install tpm and the plugins into ~/.tmux/plugins,
# each at the commit tmux/plugins.lock pins. tpm loads them when tmux starts. On Ubuntu, have
# tmux-continuum enable its systemd user unit, which starts tmux at boot and restores the sessions.
#
# A temp HOME doesn't isolate the Ubuntu part, which enables the unit in your real user manager.
# Test it in an ubuntu:26.04 container, which has no user manager, or with systemctl stubbed, as
# tests/test-tmux-boot.sh does.
#
# The step makes one exception to how steps fail. When it can't reach the systemd user manager, as
# in a container or before your first login, it says so and passes, since tmux works without
# starting at boot and a re-run after login sets that up. Status reports the unit missing.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

PLUGIN_DIR="$HOME/.tmux/plugins"
# Lines of "<owner>/<repo> <commit>". tpm's #ref goes to git clone -b, which takes no commit, so the
# pins live here, not in tmux.conf. The tests point DOTFILES_TMUX_PLUGINS_LOCK at their own pins.
PLUGINS_LOCK="${DOTFILES_TMUX_PLUGINS_LOCK:-$DOTFILES_DIR/tmux/plugins.lock}"

# Print each pinned plugin, tpm among them, and its commit, e.g.
# tmux-plugins/tmux-yank acfd36e4fcba99f8310a7dfb432111c242fe7392
tmux_plugins() {
    awk '!/^#/ && NF { print $1, $2 }' "$PLUGINS_LOCK"
}

# Succeeds when a plugin's dir is a git checkout of the given commit. The .git check stops git
# from finding a repo above a plain dir.
# e.g. plugin_installed tmux-plugins/tmux-yank acfd36e4fcba99f8310a7dfb432111c242fe7392
plugin_installed() {
    local dir="$PLUGIN_DIR/${1##*/}"
    [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$2" ]
}

# Check out a plugin at a commit, fetching only that commit, and only when the checkout lacks it,
# so a re-run works offline. A missing or empty dir becomes a new checkout, and an existing
# checkout moves to the commit, whatever branch it was on. A plain dir with files in it, which the
# checkout could overwrite, is left for you to move.
install_tmux_plugin() {
    local repo="$1" sha="$2" dir="$PLUGIN_DIR/${1##*/}"
    if [ ! -d "$dir/.git" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        echo "  Couldn't install tmux plugin $repo: $dir isn't a git checkout, and isn't empty. Move it" >&2
        echo "  aside and re-run." >&2
        return 1
    fi
    if { [ -d "$dir/.git" ] || git init -q "$dir"; } &&
        { git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null ||
            GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch -q --depth 1 "https://github.com/$repo" "$sha"; } &&
        git -C "$dir" checkout -q --detach "$sha"; then
        echo "  Installed tmux plugin $repo at ${sha:0:7}"
        return 0
    fi
    echo "  Couldn't install tmux plugin $repo at ${sha:0:7}." >&2
    return 1
}

# Install each plugin that isn't at its pin. Fails when one fails, after trying the rest.
# upgrade.sh runs it too.
sync_tmux_plugins() {
    local repo sha status=0 changed=false
    while read -r repo sha; do
        plugin_installed "$repo" "$sha" && continue
        changed=true
        install_tmux_plugin "$repo" "$sha" || status=1
    done < <(tmux_plugins)
    "$changed" || echo "  tmux plugins already at their pinned commits."
    return "$status"
}

# Pass each file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
tmux_files() {
    local status=0
    "$1" "$DOTFILES_DIR/tmux/tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" || status=1
    "$1" "$DOTFILES_DIR/tmux/bin/tmux-sessionizer" "$HOME/.local/bin/tmux-sessionizer" || status=1
    return "$status"
}

# continuum's systemd user unit. continuum writes it to ~/.config/systemd/user and enables it when
# a tmux server loads the plugin with @continuum-boot on, which tmux.conf sets outside macOS.
TMUX_BOOT_UNIT=tmux.service

tmux_boot_enabled() {
    systemctl --user is-enabled --quiet "$TMUX_BOOT_UNIT" 2>/dev/null
}

# A running server may have loaded an older config, so start one on a socket in a new directory,
# which loads the config above. start-server returns once the config, and continuum with it, has
# run, and the server then exits, having no sessions; kill-server covers a plugin that opened one.
# continuum's restore, which it starts in the background, then finds no server and does nothing.
setup_tmux_boot() {
    local tmpdir
    if ! systemctl --user show-environment &>/dev/null; then
        echo "Couldn't reach your systemd user manager, so tmux doesn't start at boot yet. Re-run the"
        echo "step after the next reboot or login."
        return 0
    fi
    echo "Setting tmux to start at boot..."
    tmpdir="$(mktemp -d)" || return 1
    env -u TMUX TMUX_TMPDIR="$tmpdir" tmux start-server || true
    env -u TMUX TMUX_TMPDIR="$tmpdir" tmux kill-server &>/dev/null || true
    rm -rf "$tmpdir"
    if ! tmux_boot_enabled; then
        echo "  continuum didn't enable $TMUX_BOOT_UNIT, so tmux won't start at boot." >&2
        return 1
    fi
    echo "  Enabled $TMUX_BOOT_UNIT, which starts tmux at boot and restores your sessions"
}

# Only Ubuntu has an item. The plugins, read from plugins.lock, stay a loop of their own.
tmux_items() {
    items_reset
    is_ubuntu || return 0
    item "tmux starts at boot (continuum's systemd user unit, $TMUX_BOOT_UNIT)" "Start tmux at boot" \
        tmux_boot_enabled setup_tmux_boot
}

status() {
    local repo sha
    tmux_files status_file
    while read -r repo sha; do
        status_check "tmux plugin $repo at ${sha:0:7}" plugin_installed "$repo" "$sha"
    done < <(tmux_plugins)
    tmux_items
    items_status
    is_ubuntu || status_item skipped "tmux starts at boot: Ubuntu only"
    status_result
}

apply() {
    local status=0
    require_cmd git || return 1
    require_cmd tmux || return 1
    echo "Copying tmux config..."
    tmux_files copy_file || status=1
    echo "Installing tmux plugins..."
    sync_tmux_plugins || status=1
    tmux_items
    # Not grep -q, whose early exit would fail the pipeline under pipefail
    if items_status | grep '^  missing ' > /dev/null; then
        items_apply || status=1
    elif is_ubuntu; then
        echo "tmux already starts at boot."
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
