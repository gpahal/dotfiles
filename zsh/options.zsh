# Set when a person is looking at the terminal, rather than a tool reading the shell's output.
# Claude Code snapshots the shell config with `zsh -c -l`, CLAUDECODE=1, and stdout on a pipe
# (checked in 2.1.295), and either condition rules it out. CLAUDECODE is the one Claude Code sets
# on purpose; -t 1 also covers other tools, such as T3 Code's `$SHELL -ilc` PATH probe.
# reminders.zsh, sourced after this file, reads it too.
_human_tty=
[[ -z ${CLAUDECODE:-} && -t 1 ]] && _human_tty=1

# Only in a terminal, so Claude Code's snapshot doesn't copy them into its Bash tool, where
# nocaseglob would change what its globs match. rcexpandparam drops an unquoted -x${arr} when arr
# is empty, and autocd turns a mistyped command into a cd, both surprises for commands written for
# bash. extendedglob stays off: it makes ^ a glob operator, which breaks git's HEAD^.
if [[ -n $_human_tty ]]; then
    setopt correct              # Auto correct mistakes
    setopt nocaseglob           # Case insensitive globbing
    setopt rcexpandparam        # foo${arr}bar expands to one word per element
    setopt autocd               # if only directory path is entered, cd there.
fi
setopt nocheckjobs              # Don't warn about running processes when exiting
setopt numericglobsort          # Sort filenames numerically when it makes sense
setopt nobeep                   # No beep
setopt interactive_comments     # Allow `# comments` on the command line, e.g. in pasted commands
setopt auto_pushd               # cd pushes the old directory, so `cd -<Tab>` lists recent ones
setopt pushd_ignore_dups        # Keep each directory once in the stack
setopt pushd_silent             # Don't print the stack after cd
setopt no_flow_control          # Free Ctrl-S and Ctrl-Q (XON/XOFF) for zsh key bindings
