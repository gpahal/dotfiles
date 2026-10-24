#!/bin/bash
# shellcheck disable=SC2016 # $ in awk programs
set -euo pipefail

# Bump the repo's vim and tmux plugin pins to HEAD and vim-plug to its latest release; $HOME is untouched.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

VIMRC="$DOTFILES_DIR/vim/vimrc"
PLUGINS_LOCK="$DOTFILES_DIR/tmux/plugins.lock"
PLUG_VIM="$DOTFILES_DIR/vim/plug.vim"
PLUG_VIM_VERSION="$DOTFILES_DIR/vim/plug.vim.version"
PLUG_REPO=junegunn/vim-plug

usage() {
    echo "Usage: bump-plugins.sh"
    echo "Move the pinned vim and tmux plugins, and the vendored vim-plug, to their latest versions."
}

head_sha() {
    local sha
    sha="$(GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/$1" HEAD | awk 'NR == 1 { print $1 }')" || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "$sha"
}

# Replace a file with a command's output from it; a failed command leaves it as it was.
rewrite() {
    local file="$1" tmp
    shift
    tmp="$(mktemp)" || return 1
    if "$@" "$file" > "$tmp"; then
        write_back "$tmp" "$file"
        return
    fi
    rm -f "$tmp"
    return 1
}

# Report on stderr; print the new sha on stdout only when it moved.
check_pin() {
    local repo="$1" old="$2" new
    if ! new="$(head_sha "$repo")"; then
        echo "  Couldn't read $repo's HEAD, so its pin stays at ${old:0:7}." >&2
        return 1
    fi
    if [ "$new" == "$old" ]; then
        echo "  $repo: unchanged" >&2
    else
        echo "  $repo: ${old:0:7} -> ${new:0:7}, https://github.com/$repo/compare/$old...$new" >&2
        echo "$new"
    fi
}

vim_pins() {
    sed -n "s/^ *Plug '\([^']*\)'.*'commit': '\([0-9a-f]\{40\}\)'.*/\1 \2/p" "$VIMRC"
}

bump_vim_plugins() {
    local repo old new status=0
    echo "vim plugins (vim/vimrc):"
    while read -r repo old; do
        new="$(check_pin "$repo" "$old")" || { status=1; continue; }
        [ -n "$new" ] || continue
        # The sha is hex, so it's safe as a regex
        rewrite "$VIMRC" awk -v plug="Plug '$repo'" -v old="$old" -v new="$new" \
            'index($0, plug) { sub(old, new) } { print }' || status=1
    done < <(vim_pins)
    return "$status"
}

bump_tmux_plugins() {
    local repo old new status=0
    echo "tmux plugins (tmux/plugins.lock):"
    while read -r repo old; do
        new="$(check_pin "$repo" "$old")" || { status=1; continue; }
        [ -n "$new" ] || continue
        rewrite "$PLUGINS_LOCK" awk -v repo="$repo" -v new="$new" \
            '!/^#/ && $1 == repo { $2 = new } { print }' || status=1
    done < <(awk '!/^#/ && NF' "$PLUGINS_LOCK")
    return "$status"
}

# Portable across BSD and GNU sort
highest_version() {
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

latest_plug_tag() {
    GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "https://github.com/$PLUG_REPO" | sed -n 's|.*refs/tags/||p' |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | highest_version
}

bump_plug_vim() {
    local old new tmp
    echo "vim-plug (vim/plug.vim):"
    old="$(cat "$PLUG_VIM_VERSION")"
    if ! new="$(latest_plug_tag)" || [ -z "$new" ]; then
        echo "  Couldn't read vim-plug's release tags, so it stays at $old." >&2
        return 1
    fi
    # Never downgrade
    if [ "$new" == "$old" ] ||
        [ "$(printf '%s\n' "$old" "$new" | highest_version)" == "$old" ]; then
        echo "  vim-plug: unchanged"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    # Reject an error page
    if ! fetch "https://raw.githubusercontent.com/$PLUG_REPO/$new/plug.vim" "$tmp" "vim-plug $new" ||
        [ "$(head -n 1 "$tmp")" != '" vim-plug: Vim plugin manager' ] ||
        ! write_back "$tmp" "$PLUG_VIM"; then
        rm -f "$tmp"
        echo "  vim-plug stays at $old." >&2
        return 1
    fi
    echo "$new" > "$PLUG_VIM_VERSION"
    echo "  vim-plug: $old -> $new, https://github.com/$PLUG_REPO/compare/$old...$new"
}

main() {
    local status=0
    case "$#:${1:-}" in
        0:) ;;
        1:-h | 1:--help)
            usage
            return 0
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
    require_cmd git || return 1
    # check_pin reports on stderr, since its stdout is the new sha
    bump_vim_plugins 2>&1 || status=1
    bump_tmux_plugins 2>&1 || status=1
    bump_plug_vim 2>&1 || status=1
    echo
    echo "Review the diffs (git diff, and the links above), run just check and just test, and commit."
    echo "Then on each machine, re-run bash setup.sh vim tmux, which moves the installed plugins to their pins."
    [ "$status" -eq 0 ] || echo "Some pins couldn't be checked; see above. Re-run just bump-plugins to retry them." >&2
    return "$status"
}

main "$@"
