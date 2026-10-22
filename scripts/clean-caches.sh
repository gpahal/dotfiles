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

_clear_go() { go clean -cache; }
_clear_pnpm() { pnpm store prune; }
_clear_npm() { npm cache clean --force; }
_clear_brew() { brew cleanup --prune=all; }

# A cache dir only: never empty, /, or HOME
_clear_dir() {
    case "${1%/}" in
        "" | "$HOME") return 1 ;;
    esac
    rm -rf "$1"
}

# _add_cache <name> <dir> <clear-fn>; skips a missing or empty dir
_add_cache() {
    [ -n "$2" ] && [ -d "$2" ] && [ -n "$(ls -A "$2" 2> /dev/null)" ] || return 0
    CACHE_NAMES+=("$1")
    CACHE_DIRS+=("$2")
    CACHE_CLEARS+=("$3")
}

# Asking each tool finds its cache wherever its config moved it. From ~, so a project's mise.toml
# doesn't pick the tool.
collect_caches() {
    local dir cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
    CACHE_NAMES=()
    CACHE_DIRS=()
    CACHE_CLEARS=()
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
    dir="${PLAYWRIGHT_BROWSERS_PATH:-}"
    if [ -z "$dir" ]; then
        dir="$cache_home/ms-playwright"
        ! is_macos || dir="$HOME/Library/Caches/ms-playwright"
    fi
    [ "$dir" == 0 ] || _add_cache "Playwright browsers" "$dir" _clear_dir
    _add_cache "PyTorch downloads" "${TORCH_HOME:-$cache_home/torch}" _clear_dir
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
    local dry_run=false i=0 rc before_kib total_kib failed=()
    [ "${1:-}" != --dry-run ] || dry_run=true
    echo "Measuring caches..."
    collect_caches
    if [ ${#CACHE_NAMES[@]} -eq 0 ]; then
        echo "No caches to clear."
        return 0
    fi
    _list_caches
    "$dry_run" && return 0
    if ! confirm "Clear them?"; then
        if is_interactive; then
            echo "Left unchanged."
        else
            echo "Left unchanged. Run it from a terminal to clear them."
        fi
        return 0
    fi
    before_kib="$total_kib"
    while [ "$i" -lt ${#CACHE_NAMES[@]} ]; do
        echo "Clearing the ${CACHE_NAMES[i]}..."
        rc=0
        "${CACHE_CLEARS[i]}" "${CACHE_DIRS[i]}" || rc=$?
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
    if [ ${#failed[@]} -gt 0 ]; then
        echo "Failed: $(printf '%s\n' "${failed[@]}" | join_lines ', ')" >&2
        return 1
    fi
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
