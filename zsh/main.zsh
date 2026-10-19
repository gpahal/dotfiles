ZSH_DIR=${${(%):-%x}:A:h}

# For shells started without ~/.zprofile, such as `zsh -i` from an app
source "$ZSH_DIR/path.zsh"

# _cached_init [-f <config>] <tool> <args...>: source the tool's cached init script. The cache's
# first line keys it on the binary's resolved path (Homebrew bottles keep build-time mtimes, so the
# versioned path shows an upgrade), the args, and the config's mtime.
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
    # Every shell sources the cache, so one others could write, as an app's umask 0 leaves it, is
    # rewritten as the user's alone
    local -a loose=($cache(N.f:g+w:) $cache(N.f:o+w:))
    if [[ $first != $key || ${bin:A} -nt $cache || -n $loose ]]; then
        # Temp file, so a concurrent shell never reads half of it
        if ! ( umask 077 && mkdir -p ${cache:h} && { print -r -- $key && "$bin" "${@:2}" } >| $cache.$$ ); then
            rm -f $cache.$$
            return 1
        fi
        mv -f $cache.$$ $cache
    fi
    source $cache
}

autoload -U add-zsh-hook

# command-not-found before plugins, so mise's activation wraps its handler rather than losing to it
for _f in basic-settings functions aliases options history key-bindings completions title hooks \
    reminders command-not-found plugins; do
    source "$ZSH_DIR/$_f.zsh"
done
unset _f _human_tty

# Both ask to be initialized last
_cached_init zoxide init zsh
# starship errors on every prompt in a dumb terminal
[[ $TERM == dumb ]] || _cached_init starship init zsh

[[ -f $HOME/.zshrc.local ]] && source "$HOME/.zshrc.local"

# Last, so it wraps every other widget
_source_plugin zsh-syntax-highlighting
