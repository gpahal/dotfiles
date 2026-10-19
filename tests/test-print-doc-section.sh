#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
# shellcheck source=../scripts/lib/markdown.sh
source "$REPO_DIR/scripts/lib/markdown.sh"
DOTFILES_DIR="$SANDBOX/repo"
mkdir -p "$DOTFILES_DIR/sub"
cat > "$DOTFILES_DIR/README.md" <<'DOC'
# Doc

## Manual steps

### macOS

- Enable [Ghostty notifications](#ghostty-notifications), in [the list](#whats-included).
- Do [its steps](./sub/README.md#manual-steps), [the second one](#computer-use-1), and [the file](./sub/README.md).
- **Open** [the site](https://example.com/a), and [a missing heading](#not-a-heading).
- Run this:

  ~~~sh
# A comment, not a heading
  ~~~

## What's `included`

```sh
# Not a heading
```

### Ghostty notifications

## Computer use

## Computer use
DOC
printf '%s\n' '# Sub' '' '## Manual steps' '' '- See [the main steps](../README.md#manual-steps) and [manual Steps](../README.md#manual-steps).' > "$DOTFILES_DIR/sub/README.md"

run print_doc_section "$DOTFILES_DIR/README.md" "## Manual steps" "### macOS"
assert_eq 0 "$RUN_STATUS" "exit status"
assert_eq '  - Enable Ghostty notifications (see README.md), in the list (see README.md).
  - Do its steps (see sub/README.md), the second one (see README.md), and the file (see sub/README.md).
  - Open the site (https://example.com/a), and a missing heading (see README.md).
  - Run this:

    ~~~sh
  # A comment, not a heading
    ~~~' "$RUN_OUTPUT" "links in the section"

run print_doc_section "$DOTFILES_DIR/sub/README.md" "## Manual steps"
assert_eq '  - See the main steps (see README.md) and manual Steps (see README.md).' "$RUN_OUTPUT" "a link up to another doc"
test_done
