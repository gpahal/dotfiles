#!/bin/bash
set -euo pipefail

# scripts/check-docs.sh checks that README.md's step table marks "macOS only" or "Ubuntu only" each
# step one OS's STEPS lacks, and no other.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"

# A copy of the working tree, as the repo the check reads
repo="$SANDBOX/repo"
mkdir -p "$repo"
git -C "$REPO_DIR" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [ ! -f "$REPO_DIR/$f" ] || printf '%s\0' "$f"; done |
    (cd "$REPO_DIR" && tar --null -T - -cf -) | tar -C "$repo" -xf -
assert_exit 0 /bin/bash "$repo/scripts/check-docs.sh"

# A step only macOS runs, unmarked, and one both run, marked, fail the check
cp "$repo/README.md" "$SANDBOX/README.md"
sed -i.bak -e '/^| `stream-deck`/s/ macOS only |$/ |/' -e '/^| `editorconfig`/s/ |$/. Ubuntu only |/' \
    "$repo/README.md"
assert_exit 1 /bin/bash "$repo/scripts/check-docs.sh"
assert_contains "$RUN_OUTPUT" 'step table should mark stream-deck "macOS only", the only OS whose STEPS have it'
assert_contains "$RUN_OUTPUT" 'step table marks editorconfig "Ubuntu only", but both OSes'"'"' STEPS have it'
cp "$SANDBOX/README.md" "$repo/README.md"
test_done
