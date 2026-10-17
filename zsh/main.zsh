# Drop duplicate entries, e.g. when nested shells or tmux panes re-run brew shellenv
typeset -U path fpath

ZSH_DIR=${${(%):-%x}:A:h}

srcif() {
    [ -f "$1" ] && source "$1"
}

# Source a tool's shell init script, cached in ~/.cache/zsh to save running the tool on every
# start. Usage: _cached_init [-f <file>] <tool> <init args...>. Regenerates the cache when the
# binary is newer, or when it resolves to a different path or gets other arguments, which the
# cache's first line records: Homebrew keeps a bottle's build-time mtime, so after an upgrade only
# the path (with its version) shows the change. With -f, the first line also records <file>'s path
# and mtime, or that it's missing, so the cache follows a config the init script depends on even
# when it's deleted or swapped for an older one. zstat reads the mtime without forking.
_cached_init() {
    local file mtime
    if [[ $1 == -f ]]; then
        file=$2
        shift 2
    fi
    local bin=${commands[$1]} cache=${XDG_CACHE_HOME:-$HOME/.cache}/zsh/$1-init.zsh first key
    [[ -n $bin ]] || return 1
    key="# ${bin:A} ${(q)@:2}"
    if [[ -n $file ]]; then
        # Only zstat, so the module's stat builtin doesn't hide the stat command
        zmodload -F zsh/stat b:zstat 2>/dev/null
        mtime=missing
        [[ -e $file ]] && { zstat -A mtime +mtime -- $file 2>/dev/null || mtime=present; }
        key+=" -f ${(q)file:A} $mtime"
    fi
    [[ -r $cache ]] && read -r first < $cache
    if [[ $first != $key || ${bin:A} -nt $cache ]]; then
        mkdir -p ${cache:h}
        # Write to a temp file first, so shells starting at the same time never read half of it
        if ! { print -r -- $key && "$bin" "${@:2}" } >| $cache.$$; then
            rm -f $cache.$$
            return 1
        fi
        mv -f $cache.$$ $cache
    fi
    source $cache
}

# ~/.zprofile sets up Homebrew for login shells; cover shells started without it, as it does.
# shellenv prints nothing when PATH already starts with Homebrew's dirs, as in a pane of the tmux
# server systemd starts at boot, so it gets a PATH without them. The eval still prepends to the
# real PATH, and typeset -U drops the second copy.
if [[ -z ${HOMEBREW_PREFIX:-} ]]; then
    for _brew in /opt/homebrew/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
        [[ -x $_brew ]] && { eval "$(PATH=/usr/bin:/bin "$_brew" shellenv zsh)"; break }
    done
    unset _brew
fi
# A nested shell (a tmux pane) skips shellenv, and macOS's path_helper in /etc/zprofile has moved
# /usr/bin ahead of Homebrew. typeset -U keeps the first copy, so this moves Homebrew to the front.
[[ -n ${HOMEBREW_PREFIX:-} ]] && path=("$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/sbin" $path)

# command-not-found comes before plugins, whose mise activation wraps the handler it defines.
# Defined after, it would replace mise's, which installs a missing tool from the mise config.
for _f in basic-settings functions aliases options history key-bindings completions title hooks \
    reminders command-not-found plugins; do
    source "$ZSH_DIR/$_f.zsh"
done
unset _f

# zoxide and starship both ask to be initialized at the end of .zshrc; zoxide after compinit
_cached_init zoxide init zsh
# starship prints an error on every prompt in a dumb terminal, such as an editor's shell
[[ $TERM == dumb ]] || _cached_init starship init zsh

# Per-machine settings, secrets and work-only aliases. Not part of the dotfiles repo.
srcif "$HOME/.zshrc.local"

# Load last, so it wraps the widgets every plugin above defines
_source_plugin zsh-syntax-highlighting
