#!/bin/bash
set -euo pipefail

# Copy and hook in the zsh config, import history into atuin, and offer zsh as login shell.
# A temp HOME doesn't isolate login-shell changes. Test with chsh and sudo stubbed.
# Records the checkout, for upgrade and upgrade-ai-tools in aliases.zsh.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/checkout.sh
source "$DOTFILES_DIR/lib/checkout.sh"

UPGRADE_FUNCTIONS="upgrade and upgrade-ai-tools"

# Lines written to the startup files, expanded when the shell reads them. STARTUP_FILES names them.
# shellcheck disable=SC2016,SC2034
ZSHRC_LINE='source $HOME/.zsh/main.zsh'
# shellcheck disable=SC2016,SC2034
PATH_ZSH_LINE='source $HOME/.zsh/path.zsh'
# A failed . is fatal in sh
# shellcheck disable=SC2016,SC2034
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

# <startup file in ~>|<what it sources>|<variable holding the line>|<OS, or both>. ~/.zprofile runs
# after macOS's /etc/zprofile, whose path_helper reorders PATH; Ubuntu's ~/.zshenv covers it.
STARTUP_FILES=(
    ".zshrc|main.zsh|ZSHRC_LINE|both"
    ".zprofile|path.zsh|PATH_ZSH_LINE|macos"
    ".zshenv|path.zsh|PATH_ZSH_LINE|ubuntu"
    ".profile|profile.sh|PROFILE_LINE|ubuntu"
)

# has_source_line <file in ~> <line variable>
has_source_line() {
    has_line "${!2}" "$HOME/$1"
}

# add_source_line <file in ~> <what it sources> <line variable>
add_source_line() {
    append_line "${!3}" "$HOME/$1" || return 1
    echo "  Added the $2 source line to ~/$1"
}

ZSH_HISTORY="$HOME/.zsh_history"
ATUIN_DB="${ATUIN_HOME:-$HOME/.atuin}/data/history.db"

# atuin starts its database once its zsh hook first runs, so a database means the history went in,
# or atuin has kept it since. A second import would add the history again.
atuin_history_imported() {
    [ -e "$ATUIN_DB" ] || [ ! -s "$ZSH_HISTORY" ]
}

import_atuin_history() {
    require_cmd atuin || return 1
    if ! HISTFILE="$ZSH_HISTORY" atuin import zsh < /dev/null > /dev/null; then
        echo "  Couldn't import ~/.zsh_history into atuin. Run atuin import zsh to see why." >&2
        return 1
    fi
    echo "  Imported ~/.zsh_history into atuin"
}

zsh_items() {
    local entry file what var os
    items_reset
    for entry in "${STARTUP_FILES[@]}"; do
        IFS='|' read -r file what var os <<< "$entry"
        case "$os" in
            macos) is_macos || continue ;;
            ubuntu) is_ubuntu || continue ;;
        esac
        item "$what sourced in ~/$file" "Add the $what source line to ~/$file" \
            "has_source_line $file $var" "add_source_line $file $what $var"
    done
    item "Shell history imported into atuin" "Import ~/.zsh_history into atuin" \
        atuin_history_imported import_atuin_history
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
        dscl . -read "/Users/$CURRENT_USER" UserShell | awk '{print $2}'
    else
        getent passwd "$CURRENT_USER" | cut -d: -f7
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
        sudo -n chsh -s "$zsh_path" "$CURRENT_USER" && return 0
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
    if is_ubuntu; then
        status_item skipped "path.zsh sourced in ~/.zprofile: macOS only"
    else
        status_item skipped "profile.sh in ~/.zsh: Ubuntu only"
        status_item skipped "path.zsh sourced in ~/.zshenv: Ubuntu only"
        status_item skipped "profile.sh sourced in ~/.profile: Ubuntu only"
    fi
    login_shell_status
    status_checkout "$UPGRADE_FUNCTIONS"
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
    apply_checkout "$UPGRADE_FUNCTIONS" || status=1
    echo "Setting up the startup files..."
    zsh_items
    items_apply_confirmed --done "  The startup files already source the zsh config, and atuin has the history" || status=1
    set_login_shell || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
