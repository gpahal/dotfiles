#!/bin/bash
set -u

# List build and download caches with their sizes and, once confirmed, clear them.
# No set -e: a failed cache mustn't stop the ones after it. Each refills when next needed, so
# the first build, install, or test afterwards is slower. pnpm keeps packages a project uses.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CACHE_NAMES=()
CACHE_DIRS=()
CACHE_CLEARS=()
SKIPPED_CACHES=()

# Each runs from ~, where collect_caches found the cache, and is given it where the tool takes one.
# pnpm isn't: --store-dir wants the parent of the versioned dir that store path prints.
_clear_go() { GOCACHE="$1" go clean -cache; }
_clear_pnpm() { pnpm store prune; }
_clear_npm() { npm cache clean --force --cache "$1"; }
_clear_brew() { HOMEBREW_CACHE="$1" brew cleanup --prune=all; }

# Resolves the dir first, since $HOME// or a symlink can name HOME; refuses /, HOME, or a dir
# above it.
_clear_dir() {
    local dir home
    dir="$(cd -- "$1" 2> /dev/null && pwd -P)" || return 1
    home="$(cd -- "$HOME" && pwd -P)" || return 1
    # pwd -P can print // for /
    if [ -z "${dir//\//}" ] || [[ "$home/" == "$dir/"* ]]; then
        echo "Not clearing $1, which is / or holds your home folder." >&2
        return 1
    fi
    rm -rf -- "$dir"
}

# _add_cache <name> <dir> <clear-fn>; skips a missing or empty dir
_add_cache() {
    [ -n "$2" ] && [ -d "$2" ] && [ -n "$(ls -A "$2" 2> /dev/null)" ] || return 0
    CACHE_NAMES+=("$1")
    CACHE_DIRS+=("$2")
    CACHE_CLEARS+=("$3")
}

# _add_dir_cache <name> <dir> <default-dir> <cache-home>: a dir an env var names is cleared, all of
# it, only when it's the tool's default or inside the cache home; else it could be ~/Documents
_add_dir_cache() {
    local dir default home
    [ -n "$2" ] && [ -d "$2" ] && [ -n "$(ls -A "$2" 2> /dev/null)" ] || return 0
    dir="$(cd -- "$2" && pwd -P)" || return 0
    default="$(cd -- "$3" 2> /dev/null && pwd -P)" || default=""
    home="$(cd -- "$4" 2> /dev/null && pwd -P)" || home=""
    if [ "$dir" != "$default" ] && { [ -z "$home" ] || [[ "$dir" != "$home/"* ]]; }; then
        SKIPPED_CACHES+=("$1 in $2, which isn't in $4 or the default $3")
        return 0
    fi
    _add_cache "$1" "$dir" _clear_dir
}

# Asking each tool finds its cache wherever its config moved it. From ~, so a project's mise.toml
# doesn't pick the tool.
collect_caches() {
    local dir default cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
    CACHE_NAMES=()
    CACHE_DIRS=()
    CACHE_CLEARS=()
    SKIPPED_CACHES=()
    if command -v go &> /dev/null && dir="$(cd ~ && go env GOCACHE 2> /dev/null)"; then
        _add_cache "Go build cache" "$dir" _clear_go
    fi
    if command -v pnpm &> /dev/null && dir="$(cd ~ && pnpm store path 2> /dev/null)"; then
        _add_cache "pnpm store" "$dir" _clear_pnpm
    fi
    if command -v npm &> /dev/null && dir="$(cd ~ && npm config get cache 2> /dev/null)"; then
        _add_cache "npm cache" "$dir" _clear_npm
    fi
    if command -v brew &> /dev/null && dir="$(brew --cache 2> /dev/null)"; then
        _add_cache "Homebrew downloads" "$dir" _clear_brew
    fi
    # PLAYWRIGHT_BROWSERS_PATH=0 keeps browsers in each project's node_modules
    default="$cache_home/ms-playwright"
    ! is_macos || default="$HOME/Library/Caches/ms-playwright"
    dir="${PLAYWRIGHT_BROWSERS_PATH:-$default}"
    [ "$dir" == 0 ] || _add_dir_cache "Playwright browsers" "$dir" "$default" "$cache_home"
    _add_dir_cache "PyTorch downloads" "${TORCH_HOME:-$cache_home/torch}" "$cache_home/torch" \
        "$cache_home"
}

_size_kib() {
    du -sk "$1" 2> /dev/null | awk '{ print $1; found = 1 } END { if (!found) print 0 }'
}

_human_kib() {
    awk -v k="$1" 'BEGIN {
        if (k >= 1048576) printf "%.1f GiB", k / 1048576
        else if (k >= 1024) printf "%.0f MiB", k / 1024
        else printf "%d KiB", k
    }'
}

# Prints the caches and sets total_kib
_list_caches() {
    local i=0 kib
    total_kib=0
    while [ "$i" -lt ${#CACHE_NAMES[@]} ]; do
        kib="$(_size_kib "${CACHE_DIRS[i]}")"
        total_kib=$((total_kib + kib))
        printf '  %-20s %10s  %s\n' "${CACHE_NAMES[i]}" "$(_human_kib "$kib")" "${CACHE_DIRS[i]}"
        i=$((i + 1))
    done
    echo "  Total: $(_human_kib "$total_kib")"
}

clean_caches() {
    local dry_run=false i=0 rc before_kib total_kib failed=() skipped
    [ "${1:-}" != --dry-run ] || dry_run=true
    echo "Measuring caches..."
    collect_caches
    for skipped in ${SKIPPED_CACHES[@]+"${SKIPPED_CACHES[@]}"}; do
        echo "Skipping the $skipped."
    done
    if [ ${#CACHE_NAMES[@]} -eq 0 ]; then
        echo "No caches to clear."
        return 0
    fi
    _list_caches
    "$dry_run" && return 0
    if ! confirm "Clear them?"; then
        left_unchanged "" it "clear them"
        return 0
    fi
    before_kib="$total_kib"
    while [ "$i" -lt ${#CACHE_NAMES[@]} ]; do
        echo "Clearing the ${CACHE_NAMES[i]}..."
        rc=0
        (cd ~ && "${CACHE_CLEARS[i]}" "${CACHE_DIRS[i]}") || rc=$?
        if interrupted_status "$rc"; then
            echo "Interrupted; stopping." >&2
            return "$rc"
        fi
        [ "$rc" -eq 0 ] || failed+=("${CACHE_NAMES[i]}")
        i=$((i + 1))
    done
    total_kib=0
    i=0
    while [ "$i" -lt ${#CACHE_DIRS[@]} ]; do
        [ ! -d "${CACHE_DIRS[i]}" ] || total_kib=$((total_kib + $(_size_kib "${CACHE_DIRS[i]}")))
        i=$((i + 1))
    done
    echo "Freed $(_human_kib $((before_kib > total_kib ? before_kib - total_kib : 0)))."
    report_failed ${failed[@]+"${failed[@]}"}
}

main() {
    case "${1:-}" in
        "" | --dry-run) clean_caches "$@" ;;
        *)
            echo "Usage: bash scripts/clean-caches.sh [--dry-run]" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
