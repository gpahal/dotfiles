# History wrapper
function _history {
    local clear list
    zparseopts -E c=clear l=list

    if [[ -n "$clear" ]]; then
        # if -c provided, clobber the history file
        echo -n >| "$HISTFILE"
        fc -p "$HISTFILE"
        echo >&2 History file cleared.
    elif [[ -n "$list" ]]; then
        # if -l provided, run as if calling `fc' directly
        builtin fc "$@"
    else
        # unless a number is provided, show all history events (starting from 1)
        [[ ${@[-1]-} = *[0-9]* ]] && builtin fc -l "$@" || builtin fc -l "$@" 1
    fi
}

# Timestamp format
case ${HIST_STAMPS-} in
    "mm/dd/yyyy") alias history='_history -f' ;;
    "dd.mm.yyyy") alias history='_history -E' ;;
    "yyyy-mm-dd") alias history='_history -i' ;;
    "") alias history='_history' ;;
    *) alias history="_history -t '$HIST_STAMPS'" ;;
esac

## History file configuration
[ -z "$HISTFILE" ] && HISTFILE="$HOME/.zsh_history"
[ "$HISTSIZE" -lt 50000 ] && HISTSIZE=50000
[ "$SAVEHIST" -lt 10000 ] && SAVEHIST=10000

## History command configuration
setopt extended_history       # record timestamp of command in HISTFILE
# ALL_DUPS covers IGNORE_DUPS and leaves no duplicates for HIST_EXPIRE_DUPS_FIRST to expire
setopt hist_ignore_all_dups   # if a new command is a duplicate, remove the older one
setopt hist_ignore_space      # ignore commands that start with space
setopt hist_reduce_blanks     # remove superfluous blanks from each command
setopt hist_verify            # show command with history expansion to user before running it
setopt share_history          # share command history data
