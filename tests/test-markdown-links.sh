#!/bin/bash

# broken_links, which scripts/check-docs.sh and scripts/check-skills.sh run.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
