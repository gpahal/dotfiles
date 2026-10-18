#!/bin/bash
set -euo pipefail

# scripts/check-docs.sh checks the files every step copies, a new step's too before git add, but
# not an install.sh .gitignore leaves out, such as one under .scratch

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"

# A copy of the working tree, committed, as the repo the check reads
repo="$SANDBOX/repo"
mkdir -p "$repo"
git -C "$REPO_DIR" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [ ! -f "$REPO_DIR/$f" ] || printf '%s\0' "$f"; done |
    (cd "$REPO_DIR" && tar --null -T - -cf -) | tar -C "$repo" -xf -
git -C "$repo" init -q
git -C "$repo" add -A
git_commit "$repo" -m base
assert_exit 0 /bin/bash "$repo/scripts/check-docs.sh"

# A step that copies a file the Maintenance list lacks fails the check, untracked or not
add_step() {
    mkdir -p "$repo/$1"
    printf 'x\n' > "$repo/$1/conf"
    printf '%s\n' '#!/bin/bash' "${2}_files() { \"\$1\" \"\$DOTFILES_DIR/$1/conf\" \"\$HOME/.$2\"; }" > "$repo/$1/install.sh"
}
add_step newstep newstep
assert_exit 1 /bin/bash "$repo/scripts/check-docs.sh"
assert_contains "$RUN_OUTPUT" "newstep/install.sh copies newstep/conf, which README.md Maintenance's copy-back list lacks"
rm -r "$repo/newstep"

# One under .scratch, which .gitignore lists, isn't read
add_step .scratch/step scratch
assert_exit 0 /bin/bash "$repo/scripts/check-docs.sh"
test_done
