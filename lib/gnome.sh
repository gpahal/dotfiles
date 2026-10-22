# Helpers for GNOME Shell extensions and custom shortcuts, for the stream-deck, hotkeys, and vicinae
# steps. Source after lib/common.sh. They need gsettings, and busctl and jq to ask GNOME Shell what
# it loaded.
# shellcheck shell=bash

# GNOME Shell's ExtensionState
GNOME_EXTENSION_ACTIVE=1
GNOME_EXTENSION_ERROR=3
GNOME_EXTENSION_OUT_OF_DATE=4

# Whether you're logged in at the desktop, not only over SSH
gnome_session_running() {
    systemctl --user is-active --quiet graphical-session.target 2> /dev/null
}

# gsettings_list <schema> <key>: one item a line; fails when gsettings can't read the key.
# gsettings prints a GVariant: @as [] or ['a', 'b'].
gsettings_list() {
    local value
    value="$(gsettings get "$1" "$2")" || return 1
    printf '%s\n' "$value" | sed -e 's/^@as //' -e 's/^\[//' -e 's/\]$//' |
        tr ',' '\n' | sed -e "s/^ *'//" -e "s/' *$//" | grep -v '^$' || true
}

# gsettings_set_list <schema> <key>: writes the items on stdin, one a line, skipping blank lines.
# Capture the gsettings_list it edits first and return on failure, so a failed read never
# becomes a write that drops your items.
gsettings_set_list() {
    local list
    list="$({ grep -v '^$' || true; } | sed "s/.*/'&'/" | join_lines ', ')"
    if [ -n "$list" ]; then list="[$list]"; else list="@as []"; fi
    gsettings set "$1" "$2" "$list"
}

gnome_extension_enabled() {
    gsettings_list org.gnome.shell enabled-extensions | grep -qxF "$1"
}

# Adds this one, keeping the rest. GNOME loads it at the next login.
gnome_enable_extension() {
    local current
    current="$(gsettings_list org.gnome.shell enabled-extensions)" || return 1
    printf '%s\n' "$current" "$1" | gsettings_set_list org.gnome.shell enabled-extensions
}

# Prints the extension's state number and, after a tab, its error; nothing when GNOME Shell doesn't
# know it. Fails when GNOME Shell isn't running, as over SSH with no desktop login.
gnome_extension_state() {
    local info
    busctl --user status org.gnome.Shell &> /dev/null || return 1
    info="$(busctl --user --json=short call org.gnome.Shell /org/gnome/Shell org.gnome.Shell.Extensions \
        GetExtensionInfo s "$1" 2> /dev/null)" || return 1
    jq -r '.data[0] | select(.state) | "\(.state.data | floor)\t\(.error.data // "")"' <<< "$info"
}

# status_gnome_extension <uuid> <dir> <label>. Whether GNOME loaded it matters only once it's
# installed in <dir> and enabled.
status_gnome_extension() {
    local uuid="$1" dir="$2" label="$3" state="" error
    status_check "$label $uuid enabled" gnome_extension_enabled "$uuid"
    [ -f "$dir/metadata.json" ] && gnome_extension_enabled "$uuid" || return 0
    if ! state="$(gnome_extension_state "$uuid")"; then
        status_item unverified "$label loaded: GNOME Shell isn't running; check at the desktop"
        return 0
    fi
    error="${state#*$'\t'}"
    state="${state%%$'\t'*}"
    case "$state" in
        "$GNOME_EXTENSION_ACTIVE") status_item ok "$label loaded" ;;
        "$GNOME_EXTENSION_OUT_OF_DATE") status_item missing "$label loaded: it doesn't list this GNOME version in metadata.json" ;;
        "$GNOME_EXTENSION_ERROR") status_item missing "$label loaded: it failed: ${error:-no error given}" ;;
        "") status_item missing "$label loaded: log out and back in, since GNOME loads a new extension at login" ;;
        *) status_item missing "$label loaded: it's in state $state, not running; log out and back in" ;;
    esac
}

GNOME_MEDIA_KEYS=org.gnome.settings-daemon.plugins.media-keys
# shellcheck disable=SC2034 # the hotkeys and vicinae steps read it
GNOME_KEYBINDING_DIR=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings

# gnome_keybinding_get <path> <key>: the custom shortcut's name, command, or binding, quoted as
# gsettings prints it
gnome_keybinding_get() {
    gsettings get "$GNOME_MEDIA_KEYS.custom-keybinding:$1" "$2" 2> /dev/null
}

gnome_keybinding_paths() {
    gsettings_list "$GNOME_MEDIA_KEYS" custom-keybindings
}

# A string as gsettings prints it, which gsettings set also parses: in single quotes, or double
# quotes when it holds a single one, with backslashes and that quote escaped
_gsettings_string() {
    local s="${1//\\/\\\\}"
    case "$s" in
        *"'"*) s="${s//\"/\\\"}"; printf '"%s"\n' "$s" ;;
        *) printf "'%s'\n" "$s" ;;
    esac
}

# gnome_keybinding_is <path> <name> <command> <binding>: the custom shortcut is listed and set so
gnome_keybinding_is() {
    local paths
    paths="$(gnome_keybinding_paths)" && grep -qxF "$1" <<< "$paths" &&
        [ "$(gnome_keybinding_get "$1" name)" == "$(_gsettings_string "$2")" ] &&
        [ "$(gnome_keybinding_get "$1" command)" == "$(_gsettings_string "$3")" ] &&
        [ "$(gnome_keybinding_get "$1" binding)" == "$(_gsettings_string "$4")" ]
}

# An accelerator spelled one way, as GTK reads it: modifier aliases (<Ctrl> and <Primary> are
# <Control>, <Mod1> is <Alt>) in any case and order, and a letter key in either case
gnome_accelerator() {
    local accel="$1" re='^<([^>]*)>(.*)$' mod mods=""
    while [[ "$accel" =~ $re ]]; do
        mod="$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")"
        accel="${BASH_REMATCH[2]}"
        case "$mod" in
            ctrl | ctl | control | primary) mod=control ;;
            mod1) mod=alt ;;
            shft) mod="shift" ;;
        esac
        mods="$mods<$mod>"$'\n'
    done
    case "$accel" in
        [A-Z]) accel="$(tr '[:upper:]' '[:lower:]' <<< "$accel")" ;;
    esac
    printf '%s%s\n' "$(printf '%s' "$mods" | sort -u | tr -d '\n')" "$accel"
}

# gnome_keybinding_clash <binding> <own path>: prints the path of another custom shortcut on the
# same keys, however it's spelled, which GNOME would run instead
gnome_keybinding_clash() {
    local own="$2" want path binding
    want="$(gnome_accelerator "$1")"
    while IFS= read -r path; do
        [ "$path" != "$own" ] || continue
        binding="$(gnome_keybinding_get "$path" binding)" || continue
        binding="${binding#[\'\"]}"
        binding="${binding%[\'\"]}"
        if [ -n "$binding" ] && [ "$(gnome_accelerator "$binding")" == "$want" ]; then
            echo "$path"
            return 0
        fi
    done < <(gnome_keybinding_paths)
    return 1
}

# gnome_set_keybinding <path> <name> <command> <binding>, adding the path to the list, keeping yours.
# Each is passed quoted: unquoted, gsettings rejects a command that starts with a quoted word.
gnome_set_keybinding() {
    local path="$1" paths
    paths="$(gnome_keybinding_paths)" || return 1
    gsettings set "$GNOME_MEDIA_KEYS.custom-keybinding:$path" name "$(_gsettings_string "$2")" &&
        gsettings set "$GNOME_MEDIA_KEYS.custom-keybinding:$path" command "$(_gsettings_string "$3")" &&
        gsettings set "$GNOME_MEDIA_KEYS.custom-keybinding:$path" binding "$(_gsettings_string "$4")" || return 1
    ! grep -qxF "$path" <<< "$paths" || return 0
    printf '%s\n' "$paths" "$path" | gsettings_set_list "$GNOME_MEDIA_KEYS" custom-keybindings
}
