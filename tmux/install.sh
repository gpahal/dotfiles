#!/bin/bash
set -euo pipefail

# Copy the tmux config and tmux-sessionizer, and install tpm and the pinned plugins.
# On Ubuntu, a temp HOME doesn't isolate enabling the systemd user unit: test with systemctl stubbed.
# Passes without a systemd user manager, since tmux works without boot start; status reports it.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

PLUGIN_DIR="$HOME/.tmux/plugins"
# Pins live here, not in tmux.conf: tpm's #ref goes to git clone -b, which takes no commit
PLUGINS_LOCK="${DOTFILES_TMUX_PLUGINS_LOCK:-$DOTFILES_DIR/tmux/plugins.lock}"

tmux_plugins() {
    awk '!/^#/ && NF { print $1, $2 }' "$PLUGINS_LOCK"
}

# The .git check stops git from finding a repo above a plain dir
plugin_installed() {
    local dir="$PLUGIN_DIR/${1##*/}"
    [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$2" ]
}

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

# upgrade.sh runs it too
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

tmux_files() {
    local status=0
    "$1" "$DOTFILES_DIR/tmux/tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" || status=1
    "$1" "$DOTFILES_DIR/tmux/bin/tmux-sessionizer" "$HOME/.local/bin/tmux-sessionizer" || status=1
    return "$status"
}

# continuum enables it when a server loads it with @continuum-boot on (tmux.conf, outside macOS)
TMUX_BOOT_UNIT=tmux.service

tmux_boot_enabled() {
    systemctl --user is-enabled --quiet "$TMUX_BOOT_UNIT" 2>/dev/null
}

# A running server may have an older config, so start a throwaway one on a new socket; it exits
# once the config has run, having no sessions.
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
    if ! items_ok; then
        items_apply || status=1
    elif is_ubuntu; then
        echo "tmux already starts at boot."
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
