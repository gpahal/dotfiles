#!/bin/bash
set -euo pipefail

# Copy the zsh config and starship's config, hook them into ~/.zshrc and ~/.zprofile (and
# ~/.zshenv and ~/.profile on Ubuntu), and make zsh the login shell.
# A temp HOME doesn't isolate login-shell changes. Test with chsh and sudo stubbed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck disable=SC2016 # lines written to files, expanded when zsh reads them
ZSHRC_LINE='source $HOME/.zsh/main.zsh'
# Homebrew and mise shims for login shells, so tools started from a login shell (editors,
# agents) find brew and mise binaries. Interactive shells run `mise activate` in zsh/plugins.zsh
# instead, so the mise line skips them rather than run mise twice.
# shellcheck disable=SC2016
if is_macos; then
    ZPROFILE_BREW_LINE='[[ -n ${HOMEBREW_PREFIX:-} ]] || eval "$(/opt/homebrew/bin/brew shellenv zsh 2>/dev/null)"'
else
    ZPROFILE_BREW_LINE='[[ -n ${HOMEBREW_PREFIX:-} ]] || eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv zsh 2>/dev/null)"'
fi
# A nested login shell (a tmux pane) inherits HOMEBREW_PREFIX, so the line above skips shellenv,
# and macOS's path_helper in /etc/zprofile has moved /usr/bin ahead of Homebrew. This moves
# Homebrew back to the front. typeset -U drops the copies further back, here and in the lines
# after it, so a nested login shell doesn't add the other dirs twice either.
# shellcheck disable=SC2016
ZPROFILE_BREW_FIRST_LINE='[[ -n ${HOMEBREW_PREFIX:-} ]] && typeset -U path && path=("$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/sbin" $path)'
# `cargo install` and `go install` put tools here, and rustup puts cargo and rustc here too
# (runtimes/install.sh runs its installer with --no-modify-path)
# shellcheck disable=SC2016
ZPROFILE_TOOLS_LINE='path=("$HOME/.cargo/bin" "$HOME/go/bin" $path)'
# shellcheck disable=SC2016
ZPROFILE_MISE_LINE='[[ -o interactive ]] || { command -v mise &>/dev/null && eval "$(mise activate zsh --shims)"; }'
# shellcheck disable=SC2016
ZPROFILE_LOCAL_LINE='path=("$HOME/.local/bin" $path)'
# Login shells also need ~/.local/bin (claude, t3), which interactive shells get in
# basic-settings.zsh. The ChatGPT app's SSH connections to Ubuntu start Codex from a login shell,
# and on macOS `zsh -lc claude` should find the native Claude Code. Each line puts its dirs in
# front, so the last comes first: ~/.local/bin, then mise's shims, then Cargo's and Go's dirs, then
# Homebrew, the order interactive shells have once `mise activate` runs.
ZPROFILE_LINES=(
    "$ZPROFILE_BREW_LINE"
    "$ZPROFILE_BREW_FIRST_LINE"
    "$ZPROFILE_TOOLS_LINE"
    "$ZPROFILE_MISE_LINE"
    "$ZPROFILE_LOCAL_LINE"
)
# T3 Code's SSH connections check for claude and codex with `sh -lc`, which reads ~/.profile.
# Add Homebrew, where codex lives, Cargo's and Go's dirs, and mise's shims, once mise has made
# them, for its Node and Go. The desktop session reads it too, so apps opened from the dock, such
# as Zed's language servers, find these tools. Ubuntu's ~/.profile adds ~/.local/bin before these
# lines, which would leave it behind Homebrew, so add it again after: the same order as
# ~/.zprofile. The comment keeps the line from matching one already in the file, which
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
# SSH (`ssh host codex`) starts a zsh that reads only ~/.zshenv, so it also puts ~/.local/bin,
# mise's shims, Cargo's and Go's dirs, and Homebrew on PATH, in ~/.zprofile's order, without
# running brew or mise.
# Login shells get them from ~/.zprofile, and a shell started from one that set up Homebrew keeps
# the PATH it inherits.
# shellcheck disable=SC2016
ZSHENV_LINES=(
    'skip_global_compinit=1'
    '[[ -o login || -n ${HOMEBREW_PREFIX:-} || ! -d /home/linuxbrew/.linuxbrew/bin ]] || path=("$HOME/.local/bin" "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" "$HOME/.cargo/bin" "$HOME/go/bin" /home/linuxbrew/.linuxbrew/bin /home/linuxbrew/.linuxbrew/sbin $path)'
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

setup_zshrc() {
    if has_line "$ZSHRC_LINE" "$HOME/.zshrc"; then
        echo "  ~/.zshrc already sources main.zsh"
    else
        append_line "$ZSHRC_LINE" "$HOME/.zshrc" || return 1
        echo "  Added the main.zsh source line to ~/.zshrc"
    fi
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
# e.g. rewrite_lines_in_order ~/.zprofile "${ZPROFILE_LINES[@]}"
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

zprofile_set_up() { lines_in_order "$HOME/.zprofile" "${ZPROFILE_LINES[@]}"; }
profile_set_up() { lines_in_order "$HOME/.profile" "${PROFILE_LINES[@]}"; }
zshenv_set_up() { lines_in_order "$HOME/.zshenv" "${ZSHENV_LINES[@]}"; }

setup_zprofile() {
    if zprofile_set_up; then
        echo "  ~/.zprofile already sets up PATH"
        return 0
    fi
    merge_lines "$HOME/.zprofile" "${ZPROFILE_LINES[@]}" || return 1
    echo "  Updated the PATH lines in ~/.zprofile"
}

setup_profile() {
    is_ubuntu || return 0
    if profile_set_up; then
        echo "  ~/.profile already sets up Homebrew, Cargo, Go, mise, and ~/.local/bin"
        return 0
    fi
    merge_lines "$HOME/.profile" "${PROFILE_LINES[@]}" || return 1
    echo "  Updated the Homebrew, Cargo, Go, mise, and ~/.local/bin lines in ~/.profile"
}

setup_zshenv() {
    is_ubuntu || return 0
    if zshenv_set_up; then
        echo "  ~/.zshenv already skips the global compinit and sets PATH"
        return 0
    fi
    merge_lines "$HOME/.zshenv" "${ZSHENV_LINES[@]}" || return 1
    echo "  Updated the skip_global_compinit and PATH lines in ~/.zshenv"
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
    status_check "Homebrew, Cargo, Go, mise, and ~/.local/bin in ~/.zprofile, in order" zprofile_set_up
    if is_ubuntu; then
        status_check "Homebrew, Cargo, Go, mise, and ~/.local/bin in ~/.profile, in order" profile_set_up
        status_check "skip_global_compinit and PATH in ~/.zshenv" zshenv_set_up
    else
        status_item skipped "Homebrew, Cargo, Go, mise, and ~/.local/bin in ~/.profile: Ubuntu only"
        status_item skipped "skip_global_compinit and PATH in ~/.zshenv: Ubuntu only"
    fi
    login_shell_status
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
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
    setup_zshrc || status=1
    setup_zprofile || status=1
    setup_profile || status=1
    setup_zshenv || status=1
    set_login_shell || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
