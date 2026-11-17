#!/bin/bash
set -euo pipefail

# Copy and reload the Ghostty config and terminfo, and on Ubuntu install the Ghostty snap.
# A temp HOME doesn't isolate the reload signal or Ubuntu's sudo snap install: test Ubuntu in a VM.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

GHOSTTY_DIR="$(app_config_dir ghostty)"

# Not apt: 26.04's archive stays on the version it shipped with
ghostty_snap_installed() {
    snap list ghostty &>/dev/null
}

install_ghostty_snap() {
    if ! sudo snap install ghostty --classic; then
        echo "  Couldn't install the Ghostty snap." >&2
        return 1
    fi
}

# Ghostty sets TERM=xterm-ghostty, which neither OS's ncurses has, so zsh in an SSH login from
# Ghostty can't move the cursor and draws each key twice. Ghostty points its own shells at its
# terminfo; an SSH login reads ~/.terminfo. Copied, not compiled: Homebrew's tic comes first in PATH
# and writes to its own ncurses. macOS's ncurses looks in hex-named dirs, 78 for x.
GHOSTTY_TERMINFO="${DOTFILES_GHOSTTY_TERMINFO:-/snap/ghostty/current/share/terminfo/x/xterm-ghostty}"
GHOSTTY_MAC_TERMINFO="${DOTFILES_GHOSTTY_MAC_TERMINFO:-/Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty}"

ghostty_terminfo_source() {
    if is_macos; then
        echo "$GHOSTTY_MAC_TERMINFO"
    else
        echo "$GHOSTTY_TERMINFO"
    fi
}

ghostty_terminfo_dest() {
    if is_macos; then
        echo "$HOME/.terminfo/78/xterm-ghostty"
    else
        echo "$HOME/.terminfo/x/xterm-ghostty"
    fi
}

ghostty_terminfo_installed() {
    cmp -s "$(ghostty_terminfo_source)" "$(ghostty_terminfo_dest)"
}

# On Ubuntu it waits for the snap, which a no to sudo leaves out. On macOS the homebrew step
# installs Ghostty.app.
install_ghostty_terminfo() {
    local src dest hint=""
    ! is_ubuntu || ghostty_snap_installed || return 0
    src="$(ghostty_terminfo_source)" dest="$(ghostty_terminfo_dest)"
    ! is_macos || hint=" Install Ghostty with bash setup.sh homebrew, then re-run."
    if [ ! -r "$src" ]; then
        echo "  No xterm-ghostty terminfo at $src.$hint" >&2
        return 1
    fi
    mkdir -p "$(dirname "$dest")" &&
        cp "$src" "$dest" &&
        echo "  Installed the xterm-ghostty terminfo in ~/.terminfo."
}

ghostty_items() {
    items_reset
    ! is_ubuntu || item --sudo "Ghostty snap installed" "Install Ghostty from its snap (classic confinement)" \
        ghostty_snap_installed install_ghostty_snap
    # shellcheck disable=SC2088 # shown, not expanded
    item "xterm-ghostty terminfo in ~/.terminfo" "Copy the xterm-ghostty terminfo to ~/.terminfo" \
        ghostty_terminfo_installed install_ghostty_terminfo
}

install_ghostty() {
    ghostty_items
    items_apply_confirmed --done "  Ghostty and its terminfo already installed."
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
        ghostty_items
        items_status
    fi
    ghostty_files status_file
    ghostty_overrides_status
}

apply() {
    echo "Setting up Ghostty..."
    local installed=0
    ! is_ubuntu || require_cmd snap || return 1
    install_ghostty || installed=$?
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
