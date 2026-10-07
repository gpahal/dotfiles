# Completions
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # Case insensitive tab completion
zstyle ':completion:*' list-colors ''                      # Colored completion with the default colors (LS_COLORS is unset on macOS)
zstyle ':completion:*' rehash true                         # automatically find new executables in path
zstyle ':completion:*' menu select                         # Pick a match with the arrow keys
zstyle ':completion:*' group-name ''                       # Group matches by type
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'  # Header for each group

# Speed up completions
zstyle ':completion:*' accept-exact '*(N)'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.zsh/cache
