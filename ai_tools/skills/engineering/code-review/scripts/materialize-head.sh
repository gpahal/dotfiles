#!/bin/bash
set -euo pipefail

# Write the files a review reads to <tmp-dir>/head, and print that path.
# Usage: materialize-head.sh <tmp-dir> <commit>
#        materialize-head.sh <tmp-dir> --staged
#
# Run it from inside the repo under review. Given a commit, it writes every file the commit
# tracks. --staged writes the index's version of each added, copied, modified, renamed, or
# type-changed file, since the working tree may differ from what gets committed. It leaves the
# repo's branches, index, and working tree alone: the commit goes through a temporary index under
# <tmp-dir>, with no worktree, ref, or checkout. Files go through the repo's checkout filters, so
# LFS files come out as they would in a checkout, and Git LFS's smudge filter may download objects
# into .git/lfs to do it. Submodules come out as empty directories. On failure it removes what it
# wrote.

usage() {
    echo "usage: materialize-head.sh <tmp-dir> <commit|--staged>" >&2
    exit 2
}
[[ $# -eq 2 ]] || usage
what="$2"

if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "materialize-head.sh: run this from inside the repo under review" >&2
    exit 2
fi
# CDPATH could send cd elsewhere and make it print the path
if ! tmp="$(CDPATH='' cd "$1" 2>/dev/null && pwd)"; then
    echo "materialize-head.sh: the temp dir '$1' doesn't exist" >&2
    exit 2
fi
head="$tmp/head"
index="$tmp/head.index"
if [[ -e "$head" || -e "$index" ]]; then
    echo "materialize-head.sh: '$head' already exists; use a new temp dir" >&2
    exit 2
fi
if [[ "$what" != --staged ]] && ! sha="$(git rev-parse --verify --quiet "$what^{commit}")"; then
    echo "materialize-head.sh: '$what' isn't a commit in this repo" >&2
    exit 2
fi

done=false
cleanup() {
    rm -f "$index"
    "$done" || rm -rf "$head"
}
trap cleanup EXIT

# Paths from git are relative to the repo root
cd "$root"
mkdir "$head"
if [[ "$what" == --staged ]]; then
    git diff --cached --name-only --diff-filter=ACMRT -z |
        git checkout-index --prefix="$head/" -z --stdin
else
    GIT_INDEX_FILE="$index" git read-tree "$sha"
    GIT_INDEX_FILE="$index" git checkout-index --all --prefix="$head/"
fi
done=true
echo "$head"
