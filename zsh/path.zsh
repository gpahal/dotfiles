# PATH for zsh, in front of what the shell started with: ~/.local/bin (claude, t3, git-wt), then
# mise's shims outside interactive shells, then the dirs `cargo install` and `go install` put tools
# in (rustup puts cargo and rustc there too), then Homebrew's. ~/.zprofile sources this for login
# shells, after macOS's path_helper in /etc/zprofile has moved /usr/bin ahead of Homebrew, and
# main.zsh for interactive ones. On Ubuntu, ~/.zshenv sources it too, for commands run directly
# over SSH (`ssh host codex`), which read no other file. Each run moves the same dirs to the front
# in the same order, and typeset -U keeps the first copy, so running it again, or in a nested
# shell, changes nothing.
typeset -U path

if [[ -o login || -o interactive ]]; then
    # A shell started without Homebrew set up, such as the first login shell or one an app
    # starts. shellenv prints nothing at all when PATH already starts with Homebrew's dirs, which
    # would leave HOMEBREW_PREFIX unset, so it gets a PATH without them.
    if [[ -z ${HOMEBREW_PREFIX:-} ]]; then
        for _brew in /opt/homebrew/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
            [[ -x $_brew ]] && { eval "$(PATH=/usr/bin:/bin "$_brew" shellenv zsh)"; break }
        done
        unset _brew
    fi
    [[ -n ${HOMEBREW_PREFIX:-} ]] && path=("$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/sbin" $path)
else
    # Neither login nor interactive, so only ~/.zshenv sourced this. A shell started from one that
    # set up Homebrew keeps the PATH it inherits. Otherwise add Homebrew's dirs without running
    # brew, which would slow every command run over SSH.
    [[ -n ${HOMEBREW_PREFIX:-} ]] && return
    for _prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
        [[ -d $_prefix/bin ]] && { path=("$_prefix/bin" "$_prefix/sbin" $path); break }
    done
    unset _prefix
fi
path=("$HOME/.cargo/bin" "$HOME/go/bin" $path)
# Interactive shells run `mise activate` in plugins.zsh instead, which puts the tools themselves
# on PATH. The shims dir is static, so this runs nothing.
[[ -o interactive ]] || path=("${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" $path)
path=("$HOME/.local/bin" $path)
