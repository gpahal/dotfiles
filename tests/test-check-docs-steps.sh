#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"

repo="$SANDBOX/repo"
mkdir -p "$repo"
git -C "$REPO_DIR" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [ ! -f "$REPO_DIR/$f" ] || printf '%s\0' "$f"; done |
    (cd "$REPO_DIR" && tar --null -T - -cf -) | tar -C "$repo" -xf -
assert_exit 0 /bin/bash "$repo/scripts/check-docs.sh"

cp "$repo/README.md" "$SANDBOX/README.md"
sed -i.bak -e '/^| `stream-deck`/s/ macOS only |$/ |/' -e '/^| `editorconfig`/s/ |$/. Ubuntu only |/' \
    "$repo/README.md"
assert_exit 1 /bin/bash "$repo/scripts/check-docs.sh"
assert_contains "$RUN_OUTPUT" 'step table should mark stream-deck "macOS only", the only OS whose STEPS have it'
assert_contains "$RUN_OUTPUT" 'step table marks editorconfig "Ubuntu only", but both OSes'"'"' STEPS have it'
cp "$SANDBOX/README.md" "$repo/README.md"
test_done
