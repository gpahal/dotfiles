#!/bin/bash
set -euo pipefail

# Copy the tmux config and tmux-sessionizer, and install tpm and the plugins tmux.conf lists into
# ~/.tmux/plugins. On Ubuntu, have tmux-continuum enable its systemd user unit, which starts tmux
# at boot and restores the sessions.
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

PLUGIN_DIR="$HOME/.tmux/plugins"

# Print the plugins tmux.conf lists, tpm among them, e.g. tmux-plugins/tmux-yank
tmux_plugins() {
    sed -n "s/^set -g @plugin '\(.*\)'/\1/p" "$DOTFILES_DIR/tmux/tmux.conf"
}

plugin_installed() {
    [ -d "$PLUGIN_DIR/${1##*/}" ]
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
    if tmux_boot_enabled; then
        echo "tmux already starts at boot."
        return 0
    fi
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

status() {
    local plugin
    tmux_files status_file
    while IFS= read -r plugin; do
        status_check "tmux plugin $plugin" plugin_installed "$plugin"
    done < <(tmux_plugins)
    if is_ubuntu; then
        status_check "tmux starts at boot (continuum's systemd user unit, $TMUX_BOOT_UNIT)" tmux_boot_enabled
    else
        status_item skipped "tmux starts at boot: Ubuntu only"
    fi
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    local plugin missing=false status=0
    # Without tmux, tpm's install script fails with a misleading "not configured in tmux.conf"
    require_cmd git || return 1
    require_cmd tmux || return 1
    echo "Copying tmux config..."
    tmux_files copy_file || status=1
    chmod 755 "$HOME/.local/bin/tmux-sessionizer" || status=1

    if plugin_installed tmux-plugins/tpm; then
        echo "tpm already installed."
    else
        echo "Installing tmux plugin manager (tpm)..."
        git clone https://github.com/tmux-plugins/tpm "$PLUGIN_DIR/tpm" || status=1
    fi

    while IFS= read -r plugin; do
        plugin_installed "$plugin" || missing=true
    done < <(tmux_plugins)
    if ! "$missing"; then
        echo "tmux plugins already installed."
    elif [ ! -x "$PLUGIN_DIR/tpm/bin/install_plugins" ]; then
        echo "tpm isn't installed, so the tmux plugins aren't either." >&2
        status=1
    else
        echo "Installing tmux plugins..."
        # tpm reads its settings from a tmux server, and a running one may have loaded an older
        # config. Point tmux at a socket in a new directory, so tpm starts its own server with
        # the config above.
        local tmpdir
        if tmpdir="$(mktemp -d)"; then
            env -u TMUX TMUX_TMPDIR="$tmpdir" "$PLUGIN_DIR/tpm/bin/install_plugins" || status=1
            rm -rf "$tmpdir"
        else
            status=1
        fi
    fi
    if is_ubuntu; then
        setup_tmux_boot || status=1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
