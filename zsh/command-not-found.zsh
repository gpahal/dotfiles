if [[ $OSTYPE == linux* ]]; then
    # Not Homebrew's handler, which never falls back to apt's. brew only on a terminal: its
    # lookup can wait on `brew update --auto-update`, stalling a pipe or an agent's shell.
    _apt_command_not_found=/usr/lib/command-not-found
    command_not_found_handler() {
        local txt
        if (( $+commands[brew] )) && [[ -t 1 && $1 != -* ]]; then
            txt="$(brew which-formula --explain "$1" 2>/dev/null)"
        fi
        if [[ -n $txt ]]; then
            print -r -u2 -- "$txt"
        elif [[ -x $_apt_command_not_found ]]; then
            "$_apt_command_not_found" -- "$1"
        else
            print -r -u2 -- "zsh: command not found: $1"
        fi
        return 127
    }
elif [[ -n ${HOMEBREW_REPOSITORY:-} ]]; then
    HOMEBREW_COMMAND_NOT_FOUND_HANDLER="$HOMEBREW_REPOSITORY/Library/Homebrew/command-not-found/handler.sh"
    if [ -f "$HOMEBREW_COMMAND_NOT_FOUND_HANDLER" ]; then
        source "$HOMEBREW_COMMAND_NOT_FOUND_HANDLER"
    fi
fi
