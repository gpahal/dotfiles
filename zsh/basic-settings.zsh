# Colored GCC warnings and errors.
export GCC_COLORS="error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01"

# Set vim as the default editor.
export EDITOR="vim"
export VISUAL="vim"

# Update $PATH
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# Manually set your language environment
export LANG="en_US.UTF-8"

# Theming section  
autoload -U compinit colors zcalc
compinit -d
colors

# Color man pages
export LESS_TERMCAP_mb=$'\E[01;32m'
export LESS_TERMCAP_md=$'\E[01;32m'
export LESS_TERMCAP_me=$'\E[0m'
export LESS_TERMCAP_se=$'\E[0m'
export LESS_TERMCAP_so=$'\E[01;47;34m'
export LESS_TERMCAP_ue=$'\E[0m'
export LESS_TERMCAP_us=$'\E[01;36m'
export LESS="-R"
