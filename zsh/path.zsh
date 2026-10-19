# Ubuntu's /etc/zsh/zshrc runs a full compinit before ~/.zshrc reaches the once-a-day one in
# zsh/basic-settings.zsh, unless skip_global_compinit is set. ~/.zshenv sources this file there,
# before /etc/zsh/zshrc runs.
skip_global_compinit=1

# PATH for zsh, in front of what the shell started with: ~/.local/bin (claude, t3, git-wt), then
# mise's shims, then the dirs `cargo install` and `go install` put tools in (rustup puts cargo and
# rustc there too), then Homebrew's. In interactive shells, `mise activate` in plugins.zsh puts
# the tools themselves ahead of the shims. ~/.zprofile sources this for login shells, after
# macOS's path_helper in /etc/zprofile has moved /usr/bin ahead of Homebrew, and main.zsh for
# interactive ones. On Ubuntu, ~/.zshenv sources it too, for commands run directly over SSH (`ssh
# host codex`), which read no other file. Each run moves the same dirs to the front in the same
# order, and typeset -U keeps the first copy, so running it again, or in a nested shell, changes
# nothing. The same goes for fpath, which a nested shell or tmux pane inherits through FPATH.
typeset -U path fpath

# A shell that's neither login nor interactive, which only ~/.zshenv sources this for, keeps the
# PATH it inherits from one that set up Homebrew, such as a script run from an activated venv
[[ -o login || -o interactive || -z ${HOMEBREW_PREFIX:-} ]] || return 0

# Homebrew's environment, as `brew shellenv zsh` prints it, set without running brew, which would
# slow every shell that starts without it, such as one an app or a systemd service starts. A shell
# that inherits HOMEBREW_PREFIX keeps what its parent set.
if [[ -z ${HOMEBREW_PREFIX:-} ]]; then
    () {
        setopt local_options extended_glob
        local prefix
        for prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
            [[ -x $prefix/bin/brew ]] || continue
            export HOMEBREW_PREFIX=$prefix HOMEBREW_CELLAR=$prefix/Cellar
            # Homebrew's own repo is the prefix on Apple silicon, and a dir in it on Linux
            if [[ $OSTYPE == darwin* ]]; then
                export HOMEBREW_REPOSITORY=$prefix
            else
                export HOMEBREW_REPOSITORY=$prefix/Homebrew
            fi
            # A leading colon has man search its default path too, which finds Homebrew's pages
            # from PATH
            [[ -z ${MANPATH-} ]] || export MANPATH=":${${MANPATH%%:##}##:##}"
            export INFOPATH="$prefix/share/info:${INFOPATH:-}"
            return
        done
    }
fi
# Homebrew's dirs, and its completions for brew-installed tools, which neither macOS's zsh nor
# Ubuntu's has built in. HOMEBREW_PREFIX may come from a shell that added neither, such as sh
# reading ~/.profile.
if [[ -n ${HOMEBREW_PREFIX:-} ]]; then
    path=("$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/sbin" $path)
    fpath=("$HOMEBREW_PREFIX/share/zsh/site-functions" $fpath)
    export FPATH
fi
path=("$HOME/.cargo/bin" "$HOME/go/bin" $path)
# The shims dir is static, so this runs nothing
path=("$HOME/.local/bin" "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" $path)
