#!/bin/bash
# shellcheck disable=SC2016 # backquotes and $ in sed and grep patterns
set -euo pipefail

# Check the READMEs' step lists match the runners' STEPS on both OSes, step header lines,
# that each STEP_NEEDS names a setup.sh step, the Manual steps sections, and local links.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/runner.sh
source "$DOTFILES_DIR/lib/runner.sh"
# shellcheck source=lib/markdown.sh
source "$DOTFILES_DIR/scripts/lib/markdown.sh"
# shellcheck source=lib/runners.sh
source "$DOTFILES_DIR/scripts/lib/runners.sh"
# shellcheck source=lib/check.sh
source "$DOTFILES_DIR/scripts/lib/check.sh"
make_tmp

# A missing section prints nothing, which the caller reports.
section() {
    md_section "$@" || true
}

# When the list is empty, say what the check looked for, so a rewording says what to restore.
doc_words() {
    if [ -s "$1" ]; then
        tr '\n' ' ' < "$1"
    else
        echo "(nothing found: it looked for $2)"
    fi
}

backquoted() {
    printf '%s\n' "$1" | { grep -o '`[^`]*`' || true; } | tr -d '`'
}

in_both() {
    grep -Fxf "$2" "$1" || true
}

# compare <what> <expected file> <actual file> <what the check looks for>
compare() {
    if ! cmp -s "$2" "$3"; then
        fail "$1 doesn't match STEPS. STEPS: $(tr '\n' ' ' < "$2")
  The doc: $(doc_words "$3" "$4")"
    fi
}

# A failed --help leaves the list empty, which the loop below reports
runner_steps "$DOTFILES_DIR/setup.sh" Darwin > "$tmp/setup-macos" || true
runner_steps "$DOTFILES_DIR/setup.sh" Linux > "$tmp/setup-ubuntu" || true
runner_steps "$DOTFILES_DIR/ai_tools/setup.sh" Darwin > "$tmp/ai-macos" || true
runner_steps "$DOTFILES_DIR/ai_tools/setup.sh" Linux > "$tmp/ai-ubuntu" || true
for list in setup-macos setup-ubuntu ai-macos ai-ubuntu; do
    [ -s "$tmp/$list" ] || fail "Couldn't read the steps for $list from the runner's --help"
done

check_header_line() {
    local script="$1" line
    line="$(step_header_line "$script")"
    if [ -z "$line" ]; then
        fail "${script#"$DOTFILES_DIR"/} has no header line, the comment after the shebang that --help lists"
    elif [ "${#line}" -gt 90 ] || [ "${line%.}" == "$line" ]; then
        fail "${script#"$DOTFILES_DIR"/}'s header line, which --help lists, should be one sentence of at most 90 characters: $line"
    fi
}
while IFS= read -r step; do
    check_header_line "$step/install.sh"
done < <({
    sed "s|^|$DOTFILES_DIR/|" "$tmp/setup-macos" "$tmp/setup-ubuntu"
    sed "s|^|$DOTFILES_DIR/ai_tools/|" "$tmp/ai-macos" "$tmp/ai-ubuntu"
} | sort -u)

# run_steps skips a step when a step it needs fails, so each need must be a setup.sh step
cat "$tmp/setup-macos" "$tmp/setup-ubuntu" > "$tmp/setup-all"
needs=0
while IFS= read -r script; do
    for need in $(step_header_value "$script" STEP_NEEDS); do
        needs=$((needs + 1))
        grep -qxF "$need" "$tmp/setup-all" ||
            fail "${script#"$DOTFILES_DIR"/}'s STEP_NEEDS names $need, which isn't a setup.sh step"
    done
done < <(find "$DOTFILES_DIR" -name install.sh -not -path '*/.git/*' -not -path '*/node_modules/*')
[ "$needs" -gt 0 ] || fail "No install.sh has a STEP_NEEDS line, so the STEP_NEEDS check found nothing"

readme="$DOTFILES_DIR/README.md"
section "$readme" "## How setup works" | { grep '^| `' || true; } > "$tmp/table-rows"
sed 's/^| `\([^`]*\)`.*/\1/' "$tmp/table-rows" > "$tmp/table"
for os in macos ubuntu; do
    in_both "$tmp/table" "$tmp/setup-$os" > "$tmp/table-$os"
    compare "README.md How setup works's step table, for $os," "$tmp/setup-$os" "$tmp/table-$os" \
        'table rows starting "| `<step>`" under "## How setup works"'
done
while IFS= read -r step; do
    grep -qxF "$step" "$tmp/setup-all" || fail "README.md How setup works's step table has $step, which isn't in STEPS"
done < "$tmp/table"

ai_readme="$DOTFILES_DIR/ai_tools/README.md"
line="$(grep -m1 '^The steps, in order, are ' "$ai_readme" || true)"
sentence="${line#The steps, in order, are }"
backquoted "${sentence%%.*}" > "$tmp/ai-list"
compare "ai_tools/README.md's step list" "$tmp/ai-macos" "$tmp/ai-list" \
    'a line starting "The steps, in order, are `<step>`, ..." in ai_tools/README.md'

# The manual-steps scripts print these sections
for doc in README.md ai_tools/README.md; do
    for os in macOS Ubuntu; do
        md_section "$DOTFILES_DIR/$doc" "## Manual steps" "### $os" > /dev/null ||
            fail "$doc has no \"### $os\" under \"## Manual steps\", which the manual-steps scripts print"
    done
done

for doc in README.md ai_tools/README.md; do
    while IFS= read -r problem; do
        fail "$doc: $problem"
    done < <(broken_links "$DOTFILES_DIR/$doc")
done

[ "$errors" -eq 0 ]
