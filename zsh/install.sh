#!/bin/bash
set -euo pipefail

# Copy the zsh config and starship's config, hook them into ~/.zshrc and ~/.zprofile (and
# ~/.zshenv and ~/.profile on Ubuntu), and make zsh the login shell.
# A temp HOME doesn't isolate login-shell changes. Test with chsh and sudo stubbed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck disable=SC2016 # lines written to files, expanded when zsh reads them
ZSHRC_LINE='source $HOME/.zsh/main.zsh'
# zsh/path.zsh sets up PATH for zsh. Login shells, which tools such as editors and agents start
# (`zsh -lc`), read it from ~/.zprofile, after macOS's path_helper in /etc/zprofile has reordered
# PATH. main.zsh sources it for interactive shells.
# shellcheck disable=SC2016
ZPROFILE_LINE='source $HOME/.zsh/path.zsh'
# T3 Code's SSH connections check for claude and codex with `sh -lc`, which reads ~/.profile.
# Add Homebrew, where codex lives, Cargo's and Go's dirs, and mise's shims, once mise has made
# them, for its Node and Go. The desktop session reads it too, so apps opened from the dock, such
# as Zed's language servers, find these tools. Ubuntu's ~/.profile adds ~/.local/bin before these
# lines, which would leave it behind Homebrew, so add it again after: the same order as
# zsh/path.zsh. The comment keeps the line from matching one already in the file, which
# append_line would skip. Each dir goes in front even when PATH has it, as the PATH systemd gives
# the desktop session does, since brew shellenv may have put Homebrew ahead of it. A login sh
# started from another one adds them again, which changes nothing.
# shellcheck disable=SC2016
PROFILE_LINES=(
    '[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
    'PATH="$HOME/go/bin:$PATH"'
    'PATH="$HOME/.cargo/bin:$PATH"'
    '[ ! -d "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" ] || PATH="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims:$PATH"'
    'PATH="$HOME/.local/bin:$PATH" # ahead of Homebrew'
)
# Ubuntu's /etc/zsh/zshrc runs a full compinit before ~/.zshrc reaches the once-a-day one in
# zsh/basic-settings.zsh, unless ~/.zshenv sets skip_global_compinit. A command run directly over
# SSH (`ssh host codex`) starts a zsh that reads only ~/.zshenv, so it sources zsh/path.zsh too.
# shellcheck disable=SC2016
ZSHENV_LINES=(
    'skip_global_compinit=1'
    "$ZPROFILE_LINE"
)
# Pass each file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
zsh_files() {
    local file status=0
    # File by file: ~/.zsh also holds the completion cache, which a fresh copy would wipe
    for file in "$DOTFILES_DIR"/zsh/*.zsh; do
        "$1" "$file" "$HOME/.zsh/${file##*/}" || status=1
    done
    # starship reads ~/.config/starship.toml (or $STARSHIP_CONFIG), even when XDG_CONFIG_HOME is set
    "$1" "$DOTFILES_DIR/zsh/config/starship.toml" "$HOME/.config/starship.toml" || status=1
    return "$status"
}

# Succeeds when a file has each line in the given order, with any other lines between them. Only
# each line's first copy counts. awk reads the lines from the environment, since -v would expand
# backslashes in them.
lines_in_order() {
    local file="$1"
    shift
    [ -f "$file" ] || return 1
    LINES="$(printf '%s\n' "$@")" awk '
        BEGIN { n = split(ENVIRON["LINES"], want, "\n"); next_line = 1 }
        {
            for (i = 1; i <= n; i++) {
                if ($0 != want[i] || (i in seen)) continue
                seen[i] = 1
                if (i != next_line) bad = 1
                next_line = i + 1
            }
        }
        END { for (i = 1; i <= n; i++) if (!(i in seen)) bad = 1; exit bad }
    ' "$file"
}

# Insert a line right after the first copy of another line in a file, keeping its mode. awk reads
# the lines from the environment, since -v would expand backslashes in them.
insert_line_after() {
    local file="$3" tmp
    tmp="$(mktemp)" || return 1
    if ! LINE="$1" AFTER="$2" awk '{ print } !done && $0 == ENVIRON["AFTER"] { print ENVIRON["LINE"]; done = 1 }' \
        "$file" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    write_back "$tmp" "$file"
}

# Add the lines a file is missing, each right after the line before it in the list, or at the end
# when that one is missing too, so lines another installer put between them stay where they are
add_lines_in_order() {
    local file="$1" line prev=""
    shift
    for line in "$@"; do
        if ! has_line "$line" "$file"; then
            if [ -n "$prev" ] && has_line "$prev" "$file"; then
                insert_line_after "$line" "$prev" "$file" || return 1
            else
                append_line "$line" "$file" || return 1
            fi
        fi
        prev="$line"
    done
}

# Write the given lines in order where the first of them was, and drop their other copies. Every
# other line stays as it was.
# e.g. rewrite_lines_in_order ~/.profile "${PROFILE_LINES[@]}"
rewrite_lines_in_order() {
    local file="$1" tmp
    shift
    tmp="$(mktemp)" || return 1
    if ! LINES="$(printf '%s\n' "$@")" awk '
        BEGIN {
            n = split(ENVIRON["LINES"], want, "\n")
            for (i = 1; i <= n; i++) managed[want[i]] = 1
        }
        $0 in managed { if (!done) for (i = 1; i <= n; i++) print want[i]; done = 1; next }
        { print }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    write_back "$tmp" "$file"
}

# Add the lines a file is missing, keeping whatever else installers (e.g. OrbStack) put there,
# then put the lines back in order where the first one was if they're out of order: appending
# would leave Homebrew or mise's shims ahead of ~/.local/bin.
# e.g. merge_lines ~/.profile "${PROFILE_LINES[@]}"
merge_lines() {
    local file="$1"
    shift
    add_lines_in_order "$file" "$@" || return 1
    lines_in_order "$file" "$@" || rewrite_lines_in_order "$file" "$@"
}

# Add the lines a startup file is missing, in order, printing one message when it already had
# them and another when it changed
# e.g. setup_lines ~/.zprofile "  Already set up" "  Added the line" "$ZPROFILE_LINE"
setup_lines() {
    local file="$1" ok="$2" changed="$3"
    shift 3
    if lines_in_order "$file" "$@"; then
        echo "$ok"
        return 0
    fi
    merge_lines "$file" "$@" || return 1
    echo "$changed"
}

# Print the zsh to use as the login shell: apt's on Ubuntu and the system's on macOS, so the login
# shell doesn't depend on Homebrew. Both are in /etc/shells, which chsh requires.
login_zsh_path() {
    local zsh_path=/bin/zsh
    is_ubuntu && zsh_path=/usr/bin/zsh
    [ -x "$zsh_path" ] && echo "$zsh_path"
}

# Print the account's login shell. $SHELL only changes at the next login, so it's stale right
# after chsh, and it's unset under cron or docker exec.
current_login_shell() {
    if is_macos; then
        dscl . -read "/Users/$(id -un)" UserShell | awk '{print $2}'
    else
        getent passwd "$(id -un)" | cut -d: -f7
    fi
}

# Print the login shell, or $SHELL when the account can't be read
login_shell() {
    local current
    current="$(current_login_shell 2>/dev/null)" || true
    echo "${current:-${SHELL:-unknown}}"
}

# Succeeds when the login shell is login_zsh_path's zsh, by path or as the same file (Ubuntu's
# /bin/zsh is /usr/bin/zsh). Another zsh, such as Homebrew's, doesn't count: the login shell
# shouldn't depend on Homebrew.
login_shell_is_zsh() {
    local zsh_path current
    zsh_path="$(login_zsh_path)" || return 1
    current="$(login_shell)"
    [ "$current" == "$zsh_path" ] || [ "$current" -ef "$zsh_path" ]
}

# Print a status item for the login shell, naming it when it isn't the zsh setup would pick
login_shell_status() {
    local zsh_path current
    if ! zsh_path="$(login_zsh_path)"; then
        status_item missing "zsh as the login shell: zsh isn't installed"
    elif login_shell_is_zsh; then
        status_item ok "$zsh_path as the login shell"
    else
        current="$(login_shell)"
        status_item missing "$zsh_path as the login shell: it's $current"
    fi
}

set_login_shell() {
    local zsh_path current
    current="$(login_shell)"
    if login_shell_is_zsh; then
        echo "zsh is already the login shell."
        return 0
    fi
    zsh_path="$(login_zsh_path)" || return 1
    if ! confirm "Make $zsh_path your login shell (may ask for your password)?"; then
        echo "  Login shell left as $current. To switch later, run: chsh -s $zsh_path"
        return 0
    fi
    # chsh asks for the account's password, which fails unattended. Root's chsh doesn't ask.
    if sudo_cached; then
        sudo -n chsh -s "$zsh_path" "$(id -un)" && return 0
    elif chsh -s "$zsh_path"; then
        return 0
    fi
    echo "  Failed. Run manually: chsh -s $zsh_path" >&2
    return 1
}

status() {
    zsh_files status_file
    status_check "main.zsh sourced in ~/.zshrc" has_line "$ZSHRC_LINE" "$HOME/.zshrc"
    status_check "path.zsh sourced in ~/.zprofile" has_line "$ZPROFILE_LINE" "$HOME/.zprofile"
    if is_ubuntu; then
        status_check "Homebrew, Cargo, Go, mise, and ~/.local/bin in ~/.profile, in order" \
            lines_in_order "$HOME/.profile" "${PROFILE_LINES[@]}"
        status_check "skip_global_compinit and path.zsh in ~/.zshenv" \
            lines_in_order "$HOME/.zshenv" "${ZSHENV_LINES[@]}"
    else
        status_item skipped "Homebrew, Cargo, Go, mise, and ~/.local/bin in ~/.profile: Ubuntu only"
        status_item skipped "skip_global_compinit and path.zsh in ~/.zshenv: Ubuntu only"
    fi
    login_shell_status
    status_result
}

apply() {
    # Without the zsh to log in with, the startup files would be set up for a shell that never runs
    if ! login_zsh_path > /dev/null; then
        if is_ubuntu; then
            echo "  /usr/bin/zsh is missing. Run the homebrew step, which installs zsh with apt, then" >&2
            echo "  re-run this step." >&2
        else
            echo "  /bin/zsh is missing." >&2
        fi
        return 1
    fi
    local status=0
    echo "Copying zsh and starship config..."
    zsh_files copy_file || status=1
    echo "Setting up ~/.zshrc and ~/.zprofile..."
    setup_lines "$HOME/.zshrc" "  ~/.zshrc already sources main.zsh" \
        "  Added the main.zsh source line to ~/.zshrc" "$ZSHRC_LINE" || status=1
    setup_lines "$HOME/.zprofile" "  ~/.zprofile already sources path.zsh" \
        "  Added the path.zsh source line to ~/.zprofile" "$ZPROFILE_LINE" || status=1
    if is_ubuntu; then
        setup_lines "$HOME/.profile" "  ~/.profile already sets up Homebrew, Cargo, Go, mise, and ~/.local/bin" \
            "  Updated the Homebrew, Cargo, Go, mise, and ~/.local/bin lines in ~/.profile" \
            "${PROFILE_LINES[@]}" || status=1
        setup_lines "$HOME/.zshenv" "  ~/.zshenv already skips the global compinit and sources path.zsh" \
            "  Updated the skip_global_compinit and path.zsh lines in ~/.zshenv" "${ZSHENV_LINES[@]}" ||
            status=1
    fi
    set_login_shell || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
