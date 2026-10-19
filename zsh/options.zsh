# Set when a person, not a tool (Claude Code's shell snapshot, T3 Code's PATH probe), reads the
# output. reminders.zsh reads it too.
_human_tty=
[[ -z ${CLAUDECODE:-} && -t 1 ]] && _human_tty=1

# Kept out of agents' shells, where they'd surprise commands written for bash. No extendedglob:
# it breaks git's HEAD^.
if [[ -n $_human_tty ]]; then
    setopt correct
    setopt nocaseglob
    setopt rcexpandparam
    setopt autocd
fi
setopt nocheckjobs
setopt numericglobsort
setopt nobeep
setopt interactive_comments
setopt auto_pushd
setopt pushd_ignore_dups
setopt pushd_silent
setopt no_flow_control          # Frees Ctrl-S and Ctrl-Q for key bindings
