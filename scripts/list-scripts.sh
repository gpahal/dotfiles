#!/bin/bash
set -euo pipefail

# Print the repo's bash scripts NUL-separated, relative to the repo, for just lint and just parse.
# A script is a .sh file, a file in a bin directory, or a file with a bash shebang. git still lists a
# deleted but unstaged file, so skip it.

CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.."
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case "$f" in
        *.sh | */bin/*) ;;
        *) head -n 1 "$f" | grep -qE '^#!(/usr)?/bin/(env +)?bash\b' || continue ;;
    esac
    printf '%s\0' "$f"
done
