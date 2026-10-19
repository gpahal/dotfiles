#!/bin/bash
set -euo pipefail

# Copy the zsh config and starship's config, add a line that sources it to ~/.zshrc and
# ~/.zprofile (and ~/.zshenv and ~/.profile on Ubuntu), and make zsh the login shell.
# A temp HOME doesn't isolate login-shell changes. Test with chsh and sudo stubbed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# One line in each startup file sources a file the step copies, so a change to what they set
# reaches the machine with the copy.
# shellcheck disable=SC2016 # lines written to files, expanded when zsh reads them
ZSHRC_LINE='source $HOME/.zsh/main.zsh'
# zsh/path.zsh sets up PATH for zsh. Login shells, which tools such as editors and agents start
# (`zsh -lc`), read it from ~/.zprofile, after macOS's path_helper in /etc/zprofile has reordered
# PATH. main.zsh sources it for interactive shells. On Ubuntu, ~/.zshenv sources it too, for a
# command run directly over SSH (`ssh host codex`), which starts a zsh that reads only ~/.zshenv.
# shellcheck disable=SC2016
PATH_ZSH_LINE='source $HOME/.zsh/path.zsh'
# zsh/profile.sh sets up PATH for sh login shells and the desktop session on Ubuntu. It's appended
# after Ubuntu's own ~/.local/bin lines, and puts ~/.local/bin first again. The check keeps a
# missing copy from stopping sh, for which a failed . is fatal.
# shellcheck disable=SC2016
PROFILE_LINE='[ ! -r "$HOME/.zsh/profile.sh" ] || . "$HOME/.zsh/profile.sh"'

# Pass each file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
zsh_files() {
    local file status=0
    # File by file: ~/.zsh also holds the completion cache, which a fresh copy would wipe
    for file in "$DOTFILES_DIR"/zsh/*.zsh; do
        "$1" "$file" "$HOME/.zsh/${file##*/}" || status=1
    done
    # Only Ubuntu's ~/.profile sources it
    if ! is_macos; then
        "$1" "$DOTFILES_DIR/zsh/profile.sh" "$HOME/.zsh/profile.sh" || status=1
    fi
    # starship reads ~/.config/starship.toml (or $STARSHIP_CONFIG), even when XDG_CONFIG_HOME is set
    "$1" "$DOTFILES_DIR/zsh/config/starship.toml" "$HOME/.config/starship.toml" || status=1
    return "$status"
}

# Add a line to a startup file, and say so
# e.g. add_source_line ~/.zprofile path.zsh "$PATH_ZSH_LINE"
add_source_line() {
    local file="$1" what="$2" line="$3" name
    name='~'"${file#"$HOME"}"
    append_line "$line" "$file" || return 1
    echo "  Added the $what source line to $name"
}

zshrc_sources_main() { has_line "$ZSHRC_LINE" "$HOME/.zshrc"; }
zprofile_sources_path() { has_line "$PATH_ZSH_LINE" "$HOME/.zprofile"; }
zshenv_sources_path() { has_line "$PATH_ZSH_LINE" "$HOME/.zshenv"; }
profile_sources_profile() { has_line "$PROFILE_LINE" "$HOME/.profile"; }
source_main_in_zshrc() { add_source_line "$HOME/.zshrc" main.zsh "$ZSHRC_LINE"; }
source_path_in_zprofile() { add_source_line "$HOME/.zprofile" path.zsh "$PATH_ZSH_LINE"; }
source_path_in_zshenv() { add_source_line "$HOME/.zshenv" path.zsh "$PATH_ZSH_LINE"; }
source_profile_in_profile() { add_source_line "$HOME/.profile" profile.sh "$PROFILE_LINE"; }

# The source lines in the startup files. Only Ubuntu's ~/.zshenv and ~/.profile get one.
zsh_items() {
    items_reset
    item "main.zsh sourced in ~/.zshrc" "Add the main.zsh source line to ~/.zshrc" \
        zshrc_sources_main source_main_in_zshrc
    item "path.zsh sourced in ~/.zprofile" "Add the path.zsh source line to ~/.zprofile" \
        zprofile_sources_path source_path_in_zprofile
    is_ubuntu || return 0
    item "path.zsh sourced in ~/.zshenv" "Add the path.zsh source line to ~/.zshenv" \
        zshenv_sources_path source_path_in_zshenv
    item "profile.sh sourced in ~/.profile" "Add the profile.sh source line to ~/.profile" \
        profile_sources_profile source_profile_in_profile
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
    zsh_items
    items_status
    if ! is_ubuntu; then
        status_item skipped "profile.sh in ~/.zsh: Ubuntu only"
        status_item skipped "path.zsh sourced in ~/.zshenv: Ubuntu only"
        status_item skipped "profile.sh sourced in ~/.profile: Ubuntu only"
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
    echo "Setting up the startup files..."
    zsh_items
    if ! items_ok; then
        items_apply || status=1
    else
        echo "  The startup files already source the zsh config"
    fi
    set_login_shell || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
