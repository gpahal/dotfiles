#!/bin/bash
set -euo pipefail

# Copy and reload the Ghostty config, and on Ubuntu install the Ghostty snap and terminfo.
# A temp HOME doesn't isolate the reload signal or Ubuntu's sudo snap install: test Ubuntu in a VM.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

GHOSTTY_DIR="$(app_config_dir ghostty)"

# Not apt: 26.04's archive stays on 1.3.0
ghostty_snap_installed() {
    snap list ghostty &>/dev/null
}

install_ghostty_snap() {
    if ! sudo snap install ghostty --classic; then
        echo "  Couldn't install the Ghostty snap." >&2
        return 1
    fi
}

# Ghostty sets TERM=xterm-ghostty, which Ubuntu's ncurses lacks, so zsh can't move the cursor over
# SSH. Copied, not compiled: Homebrew's tic comes first in PATH and writes to its own ncurses.
GHOSTTY_TERMINFO="${DOTFILES_GHOSTTY_TERMINFO:-/snap/ghostty/current/share/terminfo/x/xterm-ghostty}"

ghostty_terminfo_installed() {
    cmp -s "$GHOSTTY_TERMINFO" "$HOME/.terminfo/x/xterm-ghostty"
}

install_ghostty_terminfo() {
    if [ ! -r "$GHOSTTY_TERMINFO" ]; then
        echo "  No xterm-ghostty terminfo at $GHOSTTY_TERMINFO." >&2
        return 1
    fi
    mkdir -p "$HOME/.terminfo/x" &&
        cp "$GHOSTTY_TERMINFO" "$HOME/.terminfo/x/xterm-ghostty" &&
        echo "  Installed the xterm-ghostty terminfo in ~/.terminfo."
}

ghostty_items() {
    items_reset
    item --sudo "Ghostty snap installed" "Install Ghostty from its snap (classic confinement)" \
        ghostty_snap_installed install_ghostty_snap
    # shellcheck disable=SC2088 # shown, not expanded
    item "xterm-ghostty terminfo in ~/.terminfo" "Copy the xterm-ghostty terminfo to ~/.terminfo" \
        ghostty_terminfo_installed install_ghostty_terminfo
}

install_ghostty() {
    local pending=()
    ghostty_items
    if items_ok; then
        echo "  Ghostty and its terminfo already installed."
        return 0
    fi
    items_pending
    if [ ${#pending[@]} -gt 0 ]; then
        confirm_sudo_changes "${pending[@]}" || return 0
    fi
    items_apply
}

ghostty_files() {
    "$1" "$DOTFILES_DIR/ghostty/config.ghostty" "$GHOSTTY_DIR/config.ghostty"
}

# Keybinds are keyed by trigger, since another trigger adds a binding rather than replacing one
ghostty_settings() {
    [ -r "$1" ] || return 0
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            key = $0; sub(/[[:space:]]*=.*/, "", key); sub(/^[[:space:]]+/, "", key)
            if (key == "keybind") {
                value = $0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/=.*/, "", value)
                key = key " " value
            }
            print key
        }
    ' "$1" | LC_ALL=C sort -u
}

# Ghostty loads Application Support's configs after config.ghostty, so they override it
ghostty_overrides_status() {
    local file overrides
    local support="$HOME/Library/Application Support/com.mitchellh.ghostty"
    is_macos || return 0
    for file in "$support/config" "$support/config.ghostty"; do
        overrides="$(LC_ALL=C comm -12 <(ghostty_settings "$file") \
            <(ghostty_settings "$DOTFILES_DIR/ghostty/config.ghostty") | join_lines ', ')"
        # shellcheck disable=SC2088 # shown, not expanded
        [ -z "$overrides" ] ||
            status_item missing "~/${file#"$HOME"/}: Ghostty loads it after config.ghostty, so it overrides the repo's $overrides; merge it into the repo's config or remove it"
    done
}

status() {
    if is_ubuntu; then
        if status_require_cmd snap "Ghostty snap"; then
            ghostty_items
            items_status
        fi
    else
        status_item skipped "Ghostty snap: the homebrew step installs Ghostty on macOS"
    fi
    ghostty_files status_file
    ghostty_overrides_status
}

apply() {
    echo "Setting up Ghostty..."
    local installed=0
    ! is_ubuntu || require_cmd snap || return 1
    if is_ubuntu; then
        install_ghostty || installed=$?
    fi
    COPIED=false
    ghostty_files copy_file || installed=1
    if "$COPIED"; then
        # SIGUSR2 reloads the config; other signals quit Ghostty
        if pkill -USR2 -x ghostty; then
            echo "  Reloaded Ghostty config."
        else
            echo "  Ghostty is not running; skipping reload."
        fi
    fi
    return "$installed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
