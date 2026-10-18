#!/bin/bash
set -euo pipefail

# Copy the Ghostty config and, when it changed, reload it in running Ghostty windows. On Ubuntu,
# also install Ghostty from its snap, which snapd keeps updated; the homebrew step installs it on
# macOS. Without snapd, the step still copies the config, then fails.
#
# A temp HOME doesn't isolate this step, which signals the running Ghostty to reload, and on Ubuntu
# runs sudo snap install. Test its Ubuntu side in an Ubuntu VM, such as an OrbStack machine. On
# macOS, a run signals the Ghostty you're running in.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# On macOS, not $XDG_CONFIG_HOME: Ghostty started from the Dock doesn't see one set in the shell.
# On Ubuntu, Ghostty reads $XDG_CONFIG_HOME/ghostty when that's set.
if is_macos; then
    GHOSTTY_DIR="$HOME/.config/ghostty"
else
    GHOSTTY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
fi

# The snap is built from Ghostty's own repo and snapd moves it to each release, while Ubuntu
# 26.04's archive keeps 1.3.0 with fixes only.
ghostty_snap_installed() {
    snap list ghostty &>/dev/null
}

install_ghostty() {
    if ghostty_snap_installed; then
        echo "  Ghostty already installed."
        return 0
    fi
    if ! command -v snap &>/dev/null; then
        echo "  Installing Ghostty needs snapd. Install it with: sudo apt-get install snapd" >&2
        return 1
    fi
    confirm_sudo_changes "Install Ghostty from its snap (classic confinement)" || return 0
    if ! sudo snap install ghostty --classic; then
        echo "  Couldn't install the Ghostty snap." >&2
        return 1
    fi
}

# Pass the file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
ghostty_files() {
    "$1" "$DOTFILES_DIR/ghostty/config.ghostty" "$GHOSTTY_DIR/config.ghostty"
}

# Print the settings a Ghostty config file sets, sorted, one per line: each key, or for a keybind,
# "keybind <trigger>", since another trigger adds a binding rather than replacing one
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

# On macOS, Ghostty 1.3 loads the config files in Application Support after config.ghostty
# (checked with ghostty +show-config), so a setting there that the repo's config also sets
# overrides it. Print an item for each such file.
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
        status_check "Ghostty snap installed" ghostty_snap_installed
    else
        status_item skipped "Ghostty snap: the homebrew step installs Ghostty on macOS"
    fi
    ghostty_files status_file
    ghostty_overrides_status
    status_result
}

apply() {
    echo "Setting up Ghostty..."
    # A failed install or copy fails the step, after the rest has run
    local installed=0
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
