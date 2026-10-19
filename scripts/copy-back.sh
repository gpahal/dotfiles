#!/bin/bash
set -euo pipefail

# Copy the configs the steps installed back into the repo where they differ, so a change made in
# an app or by hand, such as to Zed's settings, survives the next setup run, which overwrites it.
# Each differing file gets its diff printed and is copied over the repo's, which keeps its mode. A
# file not installed here is skipped. When two installed copies of one repo file differ, such as
# ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md, the first is copied back and the second named, to
# merge by hand, which fails the script.
# Usage: copy-back.sh [--dry-run]

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
    echo "Usage: copy-back.sh [--dry-run]"
    echo "Copy the installed configs that differ from the repo's back into the repo, printing each"
    echo "diff. --dry-run only lists them."
}

dry_run=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Print a path with HOME as ~, and a repo path relative to the repo
# shellcheck disable=SC2088 # shown, not expanded
shown() {
    case "$1" in
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        "$DOTFILES_DIR"/*) echo "${1#"$DOTFILES_DIR"/}" ;;
        *) echo "$1" ;;
    esac
}

# Record each copy every step's *_files functions name, as <repo file> <tab> <destination>. Each
# step is sourced in its own subshell, with stdin from /dev/null so nothing asks, and what sourcing
# and the functions print is dropped.
common_fns="$(compgen -A function)"
for install in "$DOTFILES_DIR"/*/install.sh "$DOTFILES_DIR"/ai_tools/*/install.sh; do
    (
        # shellcheck disable=SC2329 # the *_files functions call it
        record() { printf '%s\t%s\n' "$1" "$2" >> "$tmp/copies"; }
        # shellcheck disable=SC1090 # every step
        source "$install" > /dev/null
        for fn in $(compgen -A function | grep '_files$'); do
            ! printf '%s\n' "$common_fns" | grep -qxF "$fn" || continue
            "$fn" record > /dev/null || true
        done
    ) < /dev/null
done
touch "$tmp/copies"

found=0
conflicts=0
: > "$tmp/taken"
while IFS=$'\t' read -r src dest; do
    [ -f "$dest" ] && [ -f "$src" ] || continue
    cmp -s "$src" "$dest" && continue
    # A repo file installed twice, whose first differing copy was already taken
    first="$(awk -F '\t' -v s="$src" '$1 == s { print $2; exit }' "$tmp/taken")"
    if [ -n "$first" ]; then
        if ! cmp -s "$first" "$dest"; then
            echo "$(shown "$dest") differs from $(shown "$first"), and both are copies of $(shown "$src"). The first was taken; merge this one by hand."
            conflicts=$((conflicts + 1))
        fi
        continue
    fi
    printf '%s\t%s\n' "$src" "$dest" >> "$tmp/taken"
    found=$((found + 1))
    if "$dry_run"; then
        echo "$(shown "$dest") differs from $(shown "$src")"
        continue
    fi
    echo "=== $(shown "$dest") -> $(shown "$src")"
    diff -u -L "$(shown "$src")" -L "$(shown "$dest")" "$src" "$dest" || true
    if ! cp "$dest" "$src"; then
        echo "Couldn't copy $(shown "$dest") to $(shown "$src")" >&2
        exit 1
    fi
done < <(awk '!seen[$0]++' "$tmp/copies")

if [ "$found" -eq 0 ]; then
    echo "Every installed config matches the repo's."
elif "$dry_run"; then
    echo "Run without --dry-run to copy them back."
else
    echo "Copied $found file(s) back. Review them with git diff."
fi
[ "$conflicts" -eq 0 ]
