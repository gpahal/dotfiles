#!/bin/bash
set -euo pipefail

# Install Vicinae, a launcher with clipboard history, with the repo's shared settings.
# Copies vicinae/dotfiles.json beside your settings.json and adds it to its imports. Vicinae writes
# its settings window's changes to settings.json, whose values win over imports, so the step only
# adds the import and this OS's settings there, and --status names the repo's keys it overrides.
# On macOS the homebrew step installs the app and the step only writes ~/.config/vicinae. On Ubuntu
# it installs into ~/.local with Vicinae's installer, then turns on its GNOME extension, user
# service, and shortcut in your session whatever HOME is: test that in an Ubuntu VM with GNOME.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/gnome.sh
source "$DOTFILES_DIR/lib/gnome.sh"

# The cask on macOS; on Ubuntu, curl and jq for the installer, which it installs with apt
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

VICINAE_SHARED="$DOTFILES_DIR/vicinae/dotfiles.json"
# Relative imports resolve against settings.json's dir
VICINAE_IMPORT=dotfiles.json
VICINAE_APP=/Applications/Vicinae.app
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# Ubuntu's install. Not /usr/local, which needs sudo. Paste and snippets need root to setcap the
# input helper, so they stay off.
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

# macOS always uses ~/.config
vicinae_config_dir() {
    if is_macos; then
        echo "$HOME/.config/vicinae"
    else
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/vicinae"
    fi
}

vicinae_settings() {
    echo "$(vicinae_config_dir)/settings.json"
}

vicinae_files() {
    "$1" "$VICINAE_SHARED" "$(vicinae_config_dir)/$VICINAE_IMPORT"
}

# <key>|<value as JSON>|<what it does>: this OS's settings, which settings.json gets when it lacks
# them. On macOS Vicinae's own shortcut opens it, and "control" is Cmd, as its settings window
# writes it. GNOME supports neither of Vicinae's Wayland hotkey protocols, so there a GNOME
# shortcut opens it, and the input helper, which runs without its setcap, stays off.
vicinae_os_settings() {
    if is_macos; then
        echo 'global_shortcuts.toggle|"control+SPACE"|Cmd+Space opens Vicinae'
        echo 'input_server.enabled|true|Paste into the active window and snippets on'
    else
        echo 'input_server.enabled|false|Paste into the active window and snippets off'
    fi
}

vicinae_installed() {
    if is_macos; then
        [ -d "$VICINAE_APP" ]
    else
        [ -x "$VICINAE_BIN" ]
    fi
}

# Takes out // and /* */ comments outside strings. Vicinae writes a comment header.
strip_jsonc_comments() {
    awk '{
        out = ""
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (block) {
                if (c == "*" && substr($0, i + 1, 1) == "/") { block = 0; i++ }
                continue
            }
            if (str) {
                out = out c
                if (c == "\\") { i++; out = out substr($0, i, 1) }
                else if (c == "\"") str = 0
                continue
            }
            if (c == "/" && substr($0, i + 1, 1) == "/") break
            if (c == "/" && substr($0, i + 1, 1) == "*") { block = 1; i++; continue }
            if (c == "\"") str = 1
            out = out c
        }
        print out
    }'
}

# settings.json as one line of JSON; {} when it's missing or empty. Fails when it isn't one object.
vicinae_settings_json() {
    local file json
    file="$(vicinae_settings)"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        echo '{}'
        return 0
    fi
    json="$(strip_jsonc_comments < "$file")" || return 1
    [[ "$json" =~ [^[:space:]] ]] || json='{}'
    jq -ce -s 'if length == 1 and (.[0] | type) == "object" then .[0] else error end' <<< "$json" 2> /dev/null
}

# Adds the import and this OS's settings that are unset
settings_filter() {
    local key value
    printf '.imports = ((.imports // []) | if any(.[]; . == "%s") then . else . + ["%s"] end)' \
        "$VICINAE_IMPORT" "$VICINAE_IMPORT"
    while IFS='|' read -r key value _; do
        printf ' | if .%s == null then .%s = %s else . end' "$key" "$key" "$value"
    done < <(vicinae_os_settings)
}

settings_imported() {
    jq -e --arg f "$VICINAE_IMPORT" 'any(.imports[]?; . == $f)' <<< "$1" > /dev/null
}

# The repo's keys, as dotted paths, that settings.json also sets. Objects are walked into; a list
# is one key.
settings_overrides() {
    jq -r --slurpfile repo "$VICINAE_SHARED" '
        def leaves: if type == "object" then to_entries[] | [.key] + (.value | leaves) else [] end;
        . as $local
        | [$repo[0] | leaves | select(. as $p | ($local | try getpath($p) catch null) != null) | join(".")]
        | join(", ")' <<< "$1"
}

# Rewrites settings.json without its comments, as Vicinae does when it saves
setup_settings() {
    local file current new tmp key value text now
    vicinae_files copy_file || return 1
    file="$(vicinae_settings)"
    if ! current="$(vicinae_settings_json)"; then
        echo "  $file isn't a JSON object, even without its comments, so it was left as it is." >&2
        return 1
    fi
    new="$(jq -c "$(settings_filter)" <<< "$current")" || {
        echo "  Couldn't update $file with jq." >&2
        return 1
    }
    while IFS='|' read -r key value text; do
        now="$(jq -c ".$key" <<< "$current")"
        if [ "$now" != null ] && [ "$now" != "$value" ]; then
            echo "  Kept your $key in $file, $now. The repo's is $value."
        fi
    done < <(vicinae_os_settings)
    if [ "$new" == "$current" ]; then
        echo "  $file already imports $VICINAE_IMPORT and has this OS's settings"
        return 0
    fi
    maybe_backup "$file" || return 1
    mkdir -p "$(dirname "$file")" && tmp="$(mktemp)" || return 1
    if ! jq . <<< "$new" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    write_back "$tmp" "$file" || return 1
    settings_imported "$current" || echo "  $file imports $VICINAE_IMPORT"
    while IFS='|' read -r key value text; do
        [ "$(jq -c ".$key" <<< "$current")" != null ] || echo "  $text ($key = $value)"
    done < <(vicinae_os_settings)
}

status_settings() {
    local file json key value text now overrides
    vicinae_files status_file
    status_require_cmd jq "Vicinae's settings" || return 0
    file="$(vicinae_settings)"
    if ! json="$(vicinae_settings_json)"; then
        status_item missing "$file isn't a JSON object, even without its comments; fix it, then re-run the step"
        return 0
    fi
    status_check "$file imports $VICINAE_IMPORT" settings_imported "$json"
    while IFS='|' read -r key value text; do
        now="$(jq -c ".$key" <<< "$json")"
        [ "$now" != null ] || now=""
        status_custom_value "$text ($key)" "$now" "$value"
    done < <(vicinae_os_settings)
    overrides="$(settings_overrides "$json")"
    [ -z "$overrides" ] || status_item info "$file overrides the repo's $VICINAE_IMPORT for: $overrides"
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

unit_loaded() {
    [ "$(systemctl --user show --property=LoadState --value "$VICINAE_UNIT_NAME" 2> /dev/null)" == loaded ]
}

vicinae_command() {
    printf "'%s' toggle" "$VICINAE_BIN"
}

hotkey_current() {
    gnome_keybinding_is "$VICINAE_KEYBINDING" Vicinae "$(vicinae_command)" "$VICINAE_KEYS"
}

input_switch_free() {
    ! gsettings_list "$INPUT_SOURCE_SCHEMA" "$INPUT_SOURCE_KEY" | grep -qxF "$VICINAE_KEYS"
}

# Keeps the layout switch's other keys, such as XF86Keyboard
free_input_switch() {
    local keys
    keys="$(gsettings_list "$INPUT_SOURCE_SCHEMA" "$INPUT_SOURCE_KEY")" || return 1
    { grep -vxF "$VICINAE_KEYS" <<< "$keys" || true; } |
        gsettings_set_list "$INPUT_SOURCE_SCHEMA" "$INPUT_SOURCE_KEY" || return 1
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
    if "$changed" || ! unit_loaded; then
        systemctl --user daemon-reload || return 1
    fi
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

status_ubuntu() {
    local clash
    status_require_cmd gsettings "Vicinae's GNOME extension and shortcut" || return 0
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
}

status() {
    if is_macos; then
        if vicinae_installed; then
            status_item ok "Vicinae ($VICINAE_APP)"
        else
            status_item missing "Vicinae ($VICINAE_APP): bash setup.sh homebrew installs it"
        fi
    elif ! has_gnome_desktop; then
        status_item skipped "Vicinae: no GNOME desktop"
        return 0
    else
        status_ubuntu
    fi
    status_settings
    status_result
}

apply_ubuntu() {
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
    setup_settings || result=1
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

apply() {
    echo "Setting up Vicinae..."
    if is_macos; then
        if ! vicinae_installed; then
            echo "  Vicinae isn't installed. Run bash setup.sh homebrew first." >&2
            return 1
        fi
        require_cmd jq || return 1
        setup_settings
    elif ! has_gnome_desktop; then
        echo "  No GNOME desktop, so skipped."
    else
        apply_ubuntu
    fi
}

# For scripts/upgrade.sh on Ubuntu: the latest Vicinae, and the latest extension for this GNOME.
# brew upgrade updates the Mac's cask.
update_vicinae() {
    local before after latest result=0
    ! is_macos && has_gnome_desktop && vicinae_installed || return 0
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
