# Helpers shared by setup.sh, ai_tools/setup.sh, and every script they run, plus git/setup-signing.sh. Source it; don't run it.
# shellcheck shell=bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOTFILES_DIR

# Each step runs in its own process, so pick up Homebrew even when the calling shell hasn't
if ! command -v brew &>/dev/null && [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

confirm() {
    local reply
    is_interactive || return 1
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# Copy a file, creating the destination directory. A file that already matches is left alone.
copy_file() {
    local src="$1" dest="$2"
    if cmp -s "$src" "$dest"; then
        echo "  $dest is already up to date"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "  Copied ${src#"$DOTFILES_DIR"/} to $dest"
}

# Like copy_file, but for files that may hold changes made by hand: ask before replacing a file
# that differs, and leave it alone without a terminal
copy_file_ask() {
    local src="$1" dest="$2"
    if cmp -s "$src" "$dest"; then
        echo "  $dest is already up to date"
        return 0
    fi
    if [ -s "$dest" ] && ! confirm "  $dest differs from ${src#"$DOTFILES_DIR"/}. Replace it?"; then
        echo "  Left $dest unchanged. Merge ${src#"$DOTFILES_DIR"/} into it by hand."
        return 0
    fi
    maybe_backup "$dest"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "  Copied ${src#"$DOTFILES_DIR"/} to $dest"
}

# Append a line to a file unless it's already there. Returns non-zero when it was, so callers
# can say whether anything changed.
append_line() {
    local line="$1" file="$2"
    if [ -f "$file" ] && grep -qxF "$line" "$file"; then
        return 1
    fi
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$line" >> "$file"
}

# Before editing an existing file, ask whether to back it up to <file>.bak, unless <file>.bak
# already matches it
maybe_backup() {
    local prompt="  Back up $1 to $1.bak?"
    [ -f "$1" ] || return 0
    if [ -f "$1.bak" ]; then
        cmp -s "$1" "$1.bak" && return 0
        prompt="  Back up $1 to $1.bak (overwrites the existing $1.bak)?"
    fi
    if confirm "$prompt"; then
        cp "$1" "$1.bak"
        echo "  Backed up $1 to $1.bak"
    fi
}

# Succeeds when this script runs inside an app, e.g. in its built-in terminal
running_inside() {
    local pid=$$ comm
    while [ "${pid:-0}" -gt 1 ]; do
        comm="$(ps -o comm= -p "$pid")" || return 1
        [ "${comm##*/}" == "$1" ] && return 0
        pid="$(ps -o ppid= -p "$pid" | tr -d ' ')" || return 1
    done
    return 1
}

# Quit a running app (after asking). Returns non-zero if it is still running.
ensure_app_quit() {
    local app="$1"
    # pgrep takes a regex, so escape app names. -a counts this script's ancestors too.
    # shellcheck disable=SC2016 # a sed pattern, not an expansion
    pgrep -ax "$(printf '%s' "$app" | sed 's/[][\.*^$()+?{}|]/\\&/g')" &>/dev/null || return 0
    if running_inside "$app"; then
        echo "  $app is running this script, so it can't be quit; skipping. Re-run this script from"
        echo "  another terminal."
        return 1
    fi
    if ! confirm "  $app is running and must be quit to change its settings. Quit $app now?"; then
        echo "  $app is running; skipping. Quit $app and re-run this script."
        return 1
    fi
    osascript -e "quit app \"$app\""
    for _ in $(seq 1 20); do
        pgrep -x "$app" &>/dev/null || return 0
        sleep 0.5
    done
    echo "  $app did not quit; skipping."
    return 1
}

# Install a Homebrew cask unless it, or the path it installs, is already there. Apps that
# auto-update may have been installed outside brew.
install_cask() {
    local cask="$1" installed="${2:-}"
    if brew list --cask "$cask" &>/dev/null || { [ -n "$installed" ] && [ -e "$installed" ]; }; then
        echo "  $cask already installed."
    else
        echo "  Installing $cask..."
        brew install --cask "$cask"
    fi
}

# Print the path of the app a Homebrew cask installs, e.g. /Applications/Claude.app
cask_app_path() {
    brew info --json=v2 --cask "$1" 2>/dev/null |
        jq -r '.casks[0].artifacts[] | objects | select(has("app")) | .target // ("/Applications/" + .app[0])' |
        head -1
}

# Succeeds when a jq expression wouldn't change a JSON file, i.e. its settings are already there
json_applied() {
    [ -s "$1" ] && jq -e "($2) == ." "$1" &>/dev/null
}

# Merge a jq expression into a JSON file, creating the file if needed
json_merge() {
    local file="$1" filter="$2" tmp
    maybe_backup "$file"
    mkdir -p "$(dirname "$file")"
    [ -s "$file" ] || echo '{}' > "$file"
    tmp="$(mktemp)"
    jq "$filter" "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Set `key = value` inside `[table]` of a TOML file, keeping the other lines (comments,
# ordering) untouched. An empty `table` means the top level, before the first table.
# `value` must already be a TOML literal, e.g. '"squash"' or 'true'.
toml_set() {
    local file="$1" table="$2" key="$3" value="$4" tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp="$(mktemp)"
    awk -v table="$table" -v key="$key" -v value="$value" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function is_header(s) { return s ~ /^[ \t]*\[/ }
        function flush_blanks() { for (; blanks > 0; blanks--) print "" }
        BEGIN { header = "[" table "]"; in_table = seen_table = (table == "") }
        {
            line = $0
            if (is_header(line)) {
                # Leaving the target table without finding the key: add it after its last entry
                if (in_table && !done) {
                    print key " = " value
                    done = 1
                    # Keep a blank line between new top-level keys and the first table
                    if (table == "" && blanks == 0) blanks = 1
                }
                flush_blanks()
                in_table = (table != "" && trim(line) == header)
                if (in_table) seen_table = 1
                print line
                next
            }
            if (in_table && trim(line) == "") { blanks++; next }
            flush_blanks()
            if (in_table && !done) {
                split(line, parts, "=")
                if (index(line, "=") > 0 && trim(parts[1]) == key) {
                    print key " = " value
                    done = 1
                    next
                }
            }
            print line
        }
        END {
            if (in_table && !done) { print key " = " value; done = 1 }
            flush_blanks()
            if (!seen_table) { print ""; print header; print key " = " value }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Run named steps in order, each in its own process. A step's script comes from the caller's
# step_script function. With no names, run every step in $STEPS.
run_steps() {
    local step script
    for step in "$@"; do
        step_script "$step" > /dev/null || {
            # shellcheck disable=SC2154
            echo "Unknown step: $step. Steps: ${STEPS[*]}" >&2
            return 1
        }
    done
    # shellcheck disable=SC2154 # STEPS is set by the caller
    [ $# -gt 0 ] || set -- "${STEPS[@]}"
    for step in "$@"; do
        script="$(step_script "$step")"
        bash "$script"
    done
}
