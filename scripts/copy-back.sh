#!/bin/bash
set -euo pipefail

# Copy installed configs that differ back into the repo. Fails on a repo file with uncommitted
# changes, or on two installed copies of one file that differ from each other.

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

# shellcheck disable=SC2088 # shown, not expanded
shown() {
    case "$1" in
        "$DOTFILES_DIR"/*) echo "${1#"$DOTFILES_DIR"/}" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

# <repo file> <tab> <destination> for every step's *_files functions
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
awk '!seen[$0]++' "$tmp/copies" > "$tmp/unique"

# Snapshot repo files first, so a file installed twice is compared with its original and dry and real runs agree.
mkdir "$tmp/orig"
: > "$tmp/snapshots"
n=0
while IFS=$'\t' read -r src dest; do
    [ -f "$src" ] || continue
    ! awk -F '\t' -v s="$src" '$1 == s { found = 1 } END { exit !found }' "$tmp/snapshots" || continue
    n=$((n + 1))
    cp "$src" "$tmp/orig/$n"
    printf '%s\t%s\n' "$src" "$tmp/orig/$n" >> "$tmp/snapshots"
done < "$tmp/unique"

# True for untracked or modified files; false outside a work tree.
uncommitted() {
    git -C "$DOTFILES_DIR" rev-parse --is-inside-work-tree &>/dev/null || return 1
    ! git -C "$DOTFILES_DIR" ls-files --error-unmatch -- "$1" &>/dev/null ||
        ! git -C "$DOTFILES_DIR" diff --quiet HEAD -- "$1"
}

found=0
conflicts=0
skipped=0
: > "$tmp/taken"
while IFS=$'\t' read -r src dest; do
    [ -f "$dest" ] && [ -f "$src" ] || continue
    orig="$(awk -F '\t' -v s="$src" '$1 == s { print $2; exit }' "$tmp/snapshots")"
    cmp -s "$orig" "$dest" && continue
    first="$(awk -F '\t' -v s="$src" '$1 == s { print $2; exit }' "$tmp/taken")"
    if [ -n "$first" ]; then
        if ! cmp -s "$first" "$dest"; then
            echo "$(shown "$dest") differs from $(shown "$first"), and both are copies of $(shown "$src"). The first was taken; merge this one by hand."
            conflicts=$((conflicts + 1))
        fi
        continue
    fi
    printf '%s\t%s\n' "$src" "$dest" >> "$tmp/taken"
    if uncommitted "$src"; then
        echo "Skipped $(shown "$dest"): $(shown "$src") has uncommitted changes, which copying would overwrite. Commit or discard them, then run this again."
        skipped=$((skipped + 1))
        continue
    fi
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
done < "$tmp/unique"

if [ "$found" -eq 0 ]; then
    [ "$skipped" -gt 0 ] || echo "Every installed config matches the repo's."
elif "$dry_run"; then
    echo "Run without --dry-run to copy them back."
else
    echo "Copied $found file(s) back. Review them with git diff."
fi
[ "$conflicts" -eq 0 ] && [ "$skipped" -eq 0 ]
