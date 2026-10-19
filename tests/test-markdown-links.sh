#!/bin/bash
set -euo pipefail

# broken_links, which scripts/check-docs.sh and scripts/check-skills.sh run on the docs, flags a
# local link whose file or #anchor is missing, in an inline link or a reference definition. A link
# with a "title" checks its target alone, and a link shown in a code block isn't checked. A # line
# in a code block, its fence indented or not, makes no anchor.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# shellcheck source=../scripts/lib/markdown.sh
source "$REPO_DIR/scripts/lib/markdown.sh"
mkdir -p "$SANDBOX/docs"
printf '%s\n' '# Other' '' '## Part' > "$SANDBOX/docs/other.md"
cat > "$SANDBOX/docs/README.md" <<'DOC'
# Doc

See [other](./other.md "The other doc"), [its part](other.md#part), [here](#doc), and
[the site](https://example.com/x.md). Also [ref one][1] and [ref two][2].

[1]: ./other.md#part
[2]: ./gone.md "Gone"
 [3]: ./other.md#no-part

Broken: [missing](./missing.md), [no anchor](#nowhere), and [a comment](#a-comment).

```md
[shown, not linked](./example.md)
```

  ~~~
  [in an indented fence](./example.md)
# A comment
  ~~~
DOC

assert_eq "broken link to ./gone.md
broken anchor in ./other.md#no-part
broken link to ./missing.md
broken anchor in #nowhere
broken anchor in #a-comment" "$(broken_links "$SANDBOX/docs/README.md")" "broken links"
test_done
