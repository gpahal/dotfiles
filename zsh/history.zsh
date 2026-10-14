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
