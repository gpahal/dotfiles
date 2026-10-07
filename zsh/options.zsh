# Options
setopt correct                  # Auto correct mistakes
setopt extendedglob             # Glob operators ^ (not), ~ (except), and # (repeat)
setopt nocaseglob               # Case insensitive globbing
setopt rcexpandparam            # foo${arr}bar expands to one word per element
setopt nocheckjobs              # Don't warn about running processes when exiting
setopt numericglobsort          # Sort filenames numerically when it makes sense
setopt nobeep                   # No beep
setopt autocd                   # if only directory path is entered, cd there.
setopt interactive_comments     # Allow `# comments` on the command line, e.g. in pasted commands
setopt auto_pushd               # cd pushes the old directory, so `cd -<Tab>` lists recent ones
setopt pushd_ignore_dups        # Keep each directory once in the stack
setopt pushd_silent             # Don't print the stack after cd
setopt no_flow_control          # Free Ctrl-S and Ctrl-Q (XON/XOFF) for zsh key bindings
