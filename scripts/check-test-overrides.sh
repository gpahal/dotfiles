#!/bin/bash
set -euo pipefail

# Fail on a bare override in tests/test-*.sh: a line that redefines, as name() { or function name,
# a function that a repo step or lib defines. Such an override changes nothing once the step
# renames the function, and the test may still pass, so tests use replace_fn, as_os, or answer
# from tests/lib.sh instead. The functions come from lib/, every */lib/, every step's install.sh
# and manual-steps.sh, and the other scripts the tests load with load_script or source. Heredoc
# bodies, such as a fake step a test writes, aren't checked. Prints each override as
# file:line: name and exits 1 when there are any. Bash 3.2.

cd "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The repo scripts whose functions count, one per line, outside tests/
sources() {
    find . \( -name .git -o -name node_modules -o -path ./tests \) -prune -o -type f -name '*.sh' \
        \( -path '*/lib/*' -o -name install.sh -o -name manual-steps.sh \) -print
    # The other scripts the tests load, given relative to the repo
    # shellcheck disable=SC2016 # $REPO_DIR is text to match
    sed -nE 's/.*(load_script|source|\.) +"?(\$REPO_DIR\/)?([A-Za-z0-9_][A-Za-z0-9_./-]*\.sh).*/\3/p' tests/*.sh |
        while IFS= read -r f; do
            case "$f" in tests/* | */../*) continue ;; esac
            [ ! -f "$f" ] || echo "./$f"
        done
}

files=()
while IFS= read -r f; do
    files+=("$f")
done < <(sources | sort -u)

# One awk run: the first files define the names, then each test is checked against them. A line
# is a definition when it starts, after indentation, with name() or function name.
awk -v nsources="${#files[@]}" '
    function defined_name(line) {
        if (match(line, /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_:-]*/)) {
            line = substr(line, RSTART, RLENGTH)
            sub(/^[ \t]*function[ \t]+/, "", line)
            return line
        }
        if (match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_:-]*[ \t]*\(\)/)) {
            line = substr(line, RSTART, RLENGTH)
            sub(/^[ \t]*/, "", line)
            sub(/[ \t]*\(\)$/, "", line)
            return line
        }
        return ""
    }
    FNR == 1 { file_index++; heredoc = "" }
    # A heredoc body ends at its delimiter, alone on a line, after tabs for <<-
    heredoc != "" {
        line = $0
        if (strip_tabs) sub(/^\t+/, "", line)
        if (line == heredoc) heredoc = ""
        next
    }
    {
        name = defined_name($0)
        if (name != "") {
            if (file_index <= nsources) repo[name] = 1
            else if (name in repo) {
                file = FILENAME
                sub(/^\.\//, "", file)
                print file ":" FNR ": " name
                found = 1
            }
        }
        # A heredoc starts at <<, not <<<, with its delimiter quoted or not
        if ($0 !~ /<<</ && match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
            heredoc = substr($0, RSTART, RLENGTH)
            strip_tabs = heredoc ~ /^<<-/
            sub(/^<<-?[ \t]*/, "", heredoc)
            gsub(/["\047]/, "", heredoc)
        }
    }
    END { exit found ? 1 : 0 }
' "${files[@]}" tests/test-*.sh
