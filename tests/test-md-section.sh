#!/bin/bash

# md_section, which the docs checks and scripts/manual-steps-doc.sh read sections with: a
# heading-like line in a code fence doesn't end the section. print_doc_text, which manual-steps
# prints with: repo links name their file, web links their URL, and bold goes.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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

run md_section "$DOTFILES_DIR/README.md" "## Manual steps" "### macOS"
assert_eq 0 "$RUN_STATUS" "exit status"
assert_contains "$RUN_OUTPUT" "Then this." "the section after a fenced heading-like line"
assert_not_contains "$RUN_OUTPUT" "Next" "the section"

run print_doc_text "$DOTFILES_DIR/README.md" <<< $'1. **Bold.** See [this](#here), [that](docs/a.md#b), and [web](https://example.com).\n\n- x'
assert_eq "  1. Bold. See this (see README.md), that (see docs/a.md), and web (https://example.com).

  - x" "$RUN_OUTPUT" "print_doc_text's output"
test_done
