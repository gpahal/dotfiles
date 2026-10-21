#!/bin/bash
set -euo pipefail

# Install Vicinae, a Raycast-like launcher with clipboard history, on Super+Space.
# Installs into ~/.local with Vicinae's installer, then turns on its GNOME extension, user service,
# and shortcut in your session whatever HOME is: test it in an Ubuntu VM with a GNOME desktop.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/gnome.sh
source "$DOTFILES_DIR/lib/gnome.sh"

STEP_OS=ubuntu
# The installer needs curl and jq, which the homebrew step installs with apt
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# Not /usr/local, which needs sudo. Paste and snippets need root to setcap the input helper, so
# they stay off.
VICINAE_PREFIX="$HOME/.local"
VICINAE_BIN="$VICINAE_PREFIX/bin/vicinae"
VICINAE_INSTALLER=https://vicinae.com/install
VICINAE_UNIT_NAME=vicinae.service
# Where the installer writes it for a prefix under HOME
VICINAE_UNIT="$DATA_HOME/systemd/user/$VICINAE_UNIT_NAME"
# The Vicinae docs' extension, reviewed on extensions.gnome.org
VICINAE_EXTENSION_UUID=vicinae@dagimg-dot
VICINAE_EXTENSION_DIR="$DATA_HOME/gnome-shell/extensions/$VICINAE_EXTENSION_UUID"
EGO_URL=https://extensions.gnome.org
VICINAE_KEYS='<Super>space'
VICINAE_KEYBINDING="$GNOME_KEYBINDING_DIR/dotfiles-vicinae/"
# GNOME switches keyboard layouts on Super+Space by default
INPUT_SOURCE_SCHEMA=org.gnome.desktop.wm.keybindings
INPUT_SOURCE_KEY=switch-input-source

vicinae_installed() {
    [ -x "$VICINAE_BIN" ]
}

# The installer installs or updates to the latest release, and does nothing when it's current.
# It runs tput under set -e, which fails without TERM.
run_vicinae_installer() {
    (
        export TERM="${TERM:-dumb}"
        run_installer bash "$VICINAE_INSTALLER" "Vicinae's installer" --prefix "$VICINAE_PREFIX"
    )
}

shell_major() {
    gnome-shell --version 2> /dev/null | grep -oE '[0-9]+' | head -n 1
}

extension_installed() {
    [ -f "$VICINAE_EXTENSION_DIR/metadata.json" ]
}

installed_extension_version() {
    jq -r '.version // empty' "$VICINAE_EXTENSION_DIR/metadata.json" 2> /dev/null
}

# The newest version on extensions.gnome.org for this GNOME
latest_extension_version() {
    local major
    major="$(shell_major)" && [ -n "$major" ] || return 1
    curl -fsS --proto '=https' --connect-timeout 15 --max-time 30 \
        "$EGO_URL/extension-info/?uuid=$VICINAE_EXTENSION_UUID&shell_version=$major" 2> /dev/null |
        jq -er '.version'
}

# gnome-extensions install also compiles the settings schema, which the zip ships uncompiled
install_extension() {
    local major dir status=0
    if ! major="$(shell_major)" || [ -z "$major" ]; then
        echo "  Couldn't read GNOME Shell's version, so Vicinae's GNOME extension isn't installed." >&2
        return 1
    fi
    dir="$(mktemp -d)" || return 1
    if fetch "$EGO_URL/download-extension/$VICINAE_EXTENSION_UUID.shell-extension.zip?shell_version=$major" \
        "$dir/$VICINAE_EXTENSION_UUID.shell-extension.zip" "Vicinae's GNOME extension"; then
        gnome-extensions install --force "$dir/$VICINAE_EXTENSION_UUID.shell-extension.zip" || status=1
    else
        status=1
    fi
    rm -rf "$dir"
    [ "$status" -eq 0 ] || return 1
    echo "  Installed Vicinae's GNOME extension $(installed_extension_version). GNOME loads it at your next login."
}

unit_enabled() {
    systemctl --user is-enabled --quiet "$VICINAE_UNIT_NAME" 2> /dev/null
}

vicinae_command() {
    printf "'%s' toggle" "$VICINAE_BIN"
}

hotkey_current() {
    gnome_keybinding_paths | grep -qxF "$VICINAE_KEYBINDING" &&
        [ "$(gnome_keybinding_get "$VICINAE_KEYBINDING" name)" == "'Vicinae'" ] &&
        [ "$(gnome_keybinding_get "$VICINAE_KEYBINDING" binding)" == "'$VICINAE_KEYS'" ] &&
        [ "$(gnome_keybinding_get "$VICINAE_KEYBINDING" command)" == "\"$(vicinae_command)\"" ]
}

input_switch_free() {
    ! gsettings_list "$INPUT_SOURCE_SCHEMA" "$INPUT_SOURCE_KEY" | grep -qxF "$VICINAE_KEYS"
}

# Keeps the layout switch's other keys, such as XF86Keyboard
free_input_switch() {
    local list
    list="$(gsettings_list "$INPUT_SOURCE_SCHEMA" "$INPUT_SOURCE_KEY" | grep -vxF "$VICINAE_KEYS" |
        sed "s/.*/'&'/" | join_lines ', ')"
    if [ -n "$list" ]; then list="[$list]"; else list="@as []"; fi
    gsettings set "$INPUT_SOURCE_SCHEMA" "$INPUT_SOURCE_KEY" "$list" || return 1
    echo "  Freed Super+Space from switching keyboard layouts"
}

setup_hotkey() {
    local clash
    if clash="$(gnome_keybinding_clash "$VICINAE_KEYS" "$VICINAE_KEYBINDING")"; then
        echo "  Your shortcut at $clash has Super+Space, so Vicinae doesn't get it." >&2
        return 1
    fi
    input_switch_free || free_input_switch || return 1
    hotkey_current && return 0
    gnome_set_keybinding "$VICINAE_KEYBINDING" Vicinae "$(vicinae_command)" "$VICINAE_KEYS" || return 1
    echo "  Super+Space opens Vicinae"
}

# Restarts a running server when the installer changed it, so it runs the new version
setup_service() {
    local changed="$1"
    if ! systemctl --user show-environment &> /dev/null; then
        echo "  Couldn't reach your systemd user manager, so Vicinae's service isn't on yet. Re-run the"
        echo "  step after the next login."
        return 0
    fi
    if [ ! -f "$VICINAE_UNIT" ]; then
        echo "  Vicinae's installer didn't write $VICINAE_UNIT." >&2
        return 1
    fi
    systemctl --user daemon-reload || return 1
    unit_enabled || systemctl --user enable "$VICINAE_UNIT_NAME" || return 1
    if ! gnome_session_running; then
        echo "  No desktop session, so Vicinae starts at your next login."
    elif "$changed"; then
        systemctl --user restart "$VICINAE_UNIT_NAME" || return 1
        echo "  Restarted Vicinae."
    elif ! systemctl --user is-active --quiet "$VICINAE_UNIT_NAME"; then
        systemctl --user start "$VICINAE_UNIT_NAME" || return 1
        echo "  Started Vicinae."
    else
        echo "  Vicinae is already running."
    fi
}

status_service() {
    status_check "Vicinae's service ($VICINAE_UNIT)" test -f "$VICINAE_UNIT"
    [ -f "$VICINAE_UNIT" ] || return 0
    status_check "Vicinae starts at login" unit_enabled
    if ! gnome_session_running; then
        status_item unverified "Vicinae running: no desktop session; it starts at the next login"
    elif systemctl --user is-active --quiet "$VICINAE_UNIT_NAME" 2> /dev/null; then
        status_item ok "Vicinae running"
    else
        status_item missing "Vicinae running: journalctl --user -u $VICINAE_UNIT_NAME says why it stopped"
    fi
}

status() {
    local clash
    if ! has_gnome_desktop; then
        status_item skipped "Vicinae: no GNOME desktop"
        return 0
    fi
    status_require_cmd gsettings "Vicinae's GNOME extension and shortcut" || { status_result; return; }
    status_check "Vicinae ($VICINAE_BIN)" vicinae_installed
    status_service
    status_check "Vicinae's GNOME extension installed ($VICINAE_EXTENSION_DIR)" extension_installed
    status_gnome_extension "$VICINAE_EXTENSION_UUID" "$VICINAE_EXTENSION_DIR" "Vicinae's GNOME extension"
    if clash="$(gnome_keybinding_clash "$VICINAE_KEYS" "$VICINAE_KEYBINDING")"; then
        status_item missing "Super+Space for Vicinae: your shortcut at $clash has it; change one"
    else
        status_check "Super+Space opens Vicinae" hotkey_current
    fi
    status_check "Super+Space doesn't switch keyboard layouts ($INPUT_SOURCE_SCHEMA $INPUT_SOURCE_KEY)" input_switch_free
    status_result
}

apply() {
    echo "Setting up Vicinae..."
    if ! has_gnome_desktop; then
        echo "  No GNOME desktop, so skipped."
        return 0
    fi
    require_cmd curl || return 1
    require_cmd jq || return 1
    require_cmd gsettings || return 1
    require_cmd gnome-extensions || return 1
    local result=0 changed=false
    if ! vicinae_installed; then
        if run_vicinae_installer; then
            changed=true
            echo "  Paste into the active window and snippets stay off, since they need root. Pick a"
            echo "  clipboard entry to copy it, then press Ctrl+V."
        else
            result=1
        fi
    fi
    if ! extension_installed; then
        install_extension || result=1
    fi
    if extension_installed && ! gnome_extension_enabled "$VICINAE_EXTENSION_UUID"; then
        if gnome_enable_extension "$VICINAE_EXTENSION_UUID"; then
            echo "  Turned on Vicinae's GNOME extension. It loads at your next login."
        else
            result=1
        fi
    fi
    if vicinae_installed; then
        setup_service "$changed" || result=1
        setup_hotkey || result=1
    fi
    return "$result"
}

# For scripts/upgrade.sh: the latest Vicinae, and the latest extension for this GNOME
update_vicinae() {
    local before after latest result=0
    has_gnome_desktop && vicinae_installed || return 0
    before="$(readlink "$VICINAE_BIN" 2> /dev/null; "$VICINAE_BIN" version 2> /dev/null || true)"
    run_vicinae_installer || result=1
    after="$(readlink "$VICINAE_BIN" 2> /dev/null; "$VICINAE_BIN" version 2> /dev/null || true)"
    if [ "$before" != "$after" ] && gnome_session_running; then
        systemctl --user try-restart "$VICINAE_UNIT_NAME" || result=1
    fi
    if extension_installed; then
        if ! latest="$(latest_extension_version)"; then
            echo "Couldn't check extensions.gnome.org for a newer Vicinae GNOME extension." >&2
            result=1
        elif [ "$latest" != "$(installed_extension_version)" ]; then
            install_extension || result=1
        fi
    fi
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
