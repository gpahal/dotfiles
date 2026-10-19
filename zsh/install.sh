#!/bin/bash
set -euo pipefail

# Copy the zsh and starship config, source it at login, and offer zsh as the login shell.
# A temp HOME doesn't isolate login-shell changes. Test with chsh and sudo stubbed.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# shellcheck disable=SC2016 # lines written to files, expanded when zsh reads them
ZSHRC_LINE='source $HOME/.zsh/main.zsh'
# shellcheck disable=SC2016
PATH_ZSH_LINE='source $HOME/.zsh/path.zsh'
# A failed . is fatal in sh
# shellcheck disable=SC2016
PROFILE_LINE='[ ! -r "$HOME/.zsh/profile.sh" ] || . "$HOME/.zsh/profile.sh"'

zsh_files() {
    local file status=0
    # File by file: ~/.zsh also holds the completion cache
    for file in "$DOTFILES_DIR"/zsh/*.zsh; do
        "$1" "$file" "$HOME/.zsh/${file##*/}" || status=1
    done
    if ! is_macos; then
        "$1" "$DOTFILES_DIR/zsh/profile.sh" "$HOME/.zsh/profile.sh" || status=1
    fi
    # starship ignores XDG_CONFIG_HOME
    "$1" "$DOTFILES_DIR/zsh/config/starship.toml" "$HOME/.config/starship.toml" || status=1
    return "$status"
}

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

# Not Homebrew's zsh, so the login shell doesn't depend on Homebrew
login_zsh_path() {
    local zsh_path=/bin/zsh
    is_ubuntu && zsh_path=/usr/bin/zsh
    [ -x "$zsh_path" ] && echo "$zsh_path"
}

# Not $SHELL: it's stale after chsh and unset under cron or docker exec
current_login_shell() {
    if is_macos; then
        dscl . -read "/Users/$(id -un)" UserShell | awk '{print $2}'
    else
        getent passwd "$(id -un)" | cut -d: -f7
    fi
}

login_shell() {
    local current
    current="$(current_login_shell 2>/dev/null)" || true
    echo "${current:-${SHELL:-unknown}}"
}

# -ef: Ubuntu's /bin/zsh is /usr/bin/zsh
login_shell_is_zsh() {
    local zsh_path current
    zsh_path="$(login_zsh_path)" || return 1
    current="$(login_shell)"
    [ "$current" == "$zsh_path" ] || [ "$current" -ef "$zsh_path" ]
}

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
    # Root's chsh doesn't ask for a password
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
