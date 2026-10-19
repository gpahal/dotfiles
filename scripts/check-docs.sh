#!/bin/bash
# shellcheck disable=SC2016 # backquotes and $ in sed and grep patterns
set -euo pipefail

# Check that the docs list each runner's steps as its STEPS has them, on macOS and on Ubuntu:
# - README.md "How setup works": the step table, which holds both OSes' steps in order, and marks
#   a step "macOS only" or "Ubuntu only" when the other OS's STEPS lacks it
# - ai_tools/README.md: "The steps, in order, are ...", less the ones "Ubuntu skips"
# Also check that:
# - README.md and ai_tools/README.md each have the "Manual steps" section for macOS and Ubuntu that
#   the manual-steps scripts print
# - README.md's and ai_tools/README.md's links to local files resolve, down to their #anchors
# `just check` runs it.

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/markdown.sh
source "$REPO_DIR/scripts/lib/markdown.sh"
# shellcheck source=lib/runners.sh
source "$REPO_DIR/scripts/lib/runners.sh"
errors=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "$1" >&2
    errors=$((errors + 1))
}

# Print the section of a Markdown file under a heading, given with its #s, as md_section does. A
# missing section prints nothing, which the check that reads it reports.
section() {
    md_section "$@" || true
}

# Print the words in list file $1, or, when it's empty, the text the check looked for in the doc
# ($2), so a rewording that hides the list says what to restore
doc_words() {
    if [ -s "$1" ]; then
        tr '\n' ' ' < "$1"
    else
        echo "(nothing found: it looked for $2)"
    fi
}

# Print the backquoted words in a line of text, one per line
backquoted() {
    printf '%s\n' "$1" | { grep -o '`[^`]*`' || true; } | tr -d '`'
}

# Print the lines of the first list that are in the second, in the first's order
in_both() {
    grep -Fxf "$2" "$1" || true
}

# compare <what> <expected file> <actual file> <the text the check looks for in the doc>
compare() {
    if ! cmp -s "$2" "$3"; then
        fail "$1 doesn't match STEPS. STEPS: $(tr '\n' ' ' < "$2")
  The doc: $(doc_words "$3" "$4")"
    fi
}

# A failed --help leaves the list empty, which the loop below reports
runner_steps "$REPO_DIR/setup.sh" Darwin > "$tmp/setup-macos" || true
runner_steps "$REPO_DIR/setup.sh" Linux > "$tmp/setup-ubuntu" || true
runner_steps "$REPO_DIR/ai_tools/setup.sh" Darwin > "$tmp/ai-macos" || true
runner_steps "$REPO_DIR/ai_tools/setup.sh" Linux > "$tmp/ai-ubuntu" || true
for list in setup-macos setup-ubuntu ai-macos ai-ubuntu; do
    [ -s "$tmp/$list" ] || fail "Couldn't read the steps for $list from the runner's --help"
done

# README.md "How setup works": the first cell of each table row under the heading
readme="$REPO_DIR/README.md"
section "$readme" "## How setup works" | { grep '^| `' || true; } > "$tmp/table-rows"
sed 's/^| `\([^`]*\)`.*/\1/' "$tmp/table-rows" > "$tmp/table"
for os in macos ubuntu; do
    in_both "$tmp/table" "$tmp/setup-$os" > "$tmp/table-$os"
    compare "README.md How setup works's step table, for $os," "$tmp/setup-$os" "$tmp/table-$os" \
        'table rows starting "| `<step>`" under "## How setup works"'
done
cat "$tmp/setup-macos" "$tmp/setup-ubuntu" > "$tmp/setup-all"
while IFS= read -r step; do
    grep -qxF "$step" "$tmp/setup-all" || fail "README.md How setup works's step table has $step, which isn't in STEPS"
done < "$tmp/table"
# Each row says "macOS only" or "Ubuntu only" when one OS's STEPS lacks the step, which is how an
# Ubuntu user learns which steps run there
while IFS= read -r row; do
    step="${row#'| `'}"
    step="${step%%'`'*}"
    mark=both
    case "$row" in
        *"macOS only"*) mark=macOS ;;
        *"Ubuntu only"*) mark=Ubuntu ;;
    esac
    runs=""
    ! grep -qxF "$step" "$tmp/setup-macos" || runs=macOS
    if grep -qxF "$step" "$tmp/setup-ubuntu"; then
        [ -z "$runs" ] && runs=Ubuntu || runs=both
    fi
    [ -n "$runs" ] && [ "$runs" != "$mark" ] || continue
    case "$runs" in
        both) fail "README.md How setup works's step table marks $step \"$mark only\", but both OSes' STEPS have it" ;;
        *) fail "README.md How setup works's step table should mark $step \"$runs only\", the only OS whose STEPS have it" ;;
    esac
done < "$tmp/table-rows"

# ai_tools/README.md: one sentence lists every step, and the next says which Ubuntu skips
ai_readme="$REPO_DIR/ai_tools/README.md"
line="$(grep -m1 '^The steps, in order, are ' "$ai_readme" || true)"
sentence="${line#The steps, in order, are }"
backquoted "${sentence%%.*}" > "$tmp/ai-list"
compare "ai_tools/README.md's step list" "$tmp/ai-macos" "$tmp/ai-list" \
    'a line starting "The steps, in order, are `<step>`, ..." in ai_tools/README.md'
skips="${line#*Ubuntu skips }"
[ "$skips" != "$line" ] || skips=""
backquoted "${skips%%[;.]*}" > "$tmp/ai-skips"
grep -vxFf "$tmp/ai-skips" "$tmp/ai-list" > "$tmp/ai-ubuntu-list" || true
compare "ai_tools/README.md's step list, less what Ubuntu skips," "$tmp/ai-ubuntu" "$tmp/ai-ubuntu-list" \
    '"Ubuntu skips `<step>`" in the line starting "The steps, in order, are " in ai_tools/README.md'

# The manual-steps scripts print these sections with print_doc_section, which fails when one is
# missing or empty
for doc in README.md ai_tools/README.md; do
    for os in macOS Ubuntu; do
        md_section "$REPO_DIR/$doc" "## Manual steps" "### $os" > /dev/null ||
            fail "$doc has no \"### $os\" under \"## Manual steps\", which the manual-steps scripts print"
    done
done

for doc in README.md ai_tools/README.md; do
    while IFS= read -r problem; do
        fail "$doc: $problem"
    done < <(broken_links "$REPO_DIR/$doc")
done

[ "$errors" -eq 0 ]
