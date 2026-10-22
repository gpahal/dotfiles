#!/bin/bash
set -euo pipefail

# print_doc_section, which manual-steps prints with: a heading-like line in a code fence doesn't end
# the section.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
# shellcheck source=../scripts/lib/markdown.sh
source "$REPO_DIR/scripts/lib/markdown.sh"
DOTFILES_DIR="$SANDBOX/repo"
mkdir -p "$DOTFILES_DIR"
cat > "$DOTFILES_DIR/README.md" <<'DOC'
# Doc

## Manual steps

### macOS

- Run this:

  ~~~sh
# A comment, not a heading
  ~~~

- Then this.

## Next
DOC

run print_doc_section "$DOTFILES_DIR/README.md" "## Manual steps" "### macOS"
assert_eq 0 "$RUN_STATUS" "exit status"
assert_contains "$RUN_OUTPUT" "Then this." "the section after a fenced heading-like line"
assert_not_contains "$RUN_OUTPUT" "Next" "the section"
test_done
