# shellcheck shell=bash
# The Markdown reading that scripts/check-docs.sh, scripts/check-skills.sh, and the manual-steps
# steps share: sections, links, and anchors. It defines functions and MD_FENCE, and runs nothing.

# The line that opens or closes a code block, as an awk regex: optional indentation, then three or
# more backticks or tildes. Each function here skips code blocks by it, so a # line in one, such as
# a shell comment, is never a heading, and a link shown in one isn't a link.
MD_FENCE='^[[:space:]]*(```|~~~)'

# Print the lines of a Markdown file under the last of the given headings, each found inside the
# one before, down to the next heading at the same level or above, without blank lines at either
# end. Fails when a heading is missing or the section is empty.
# e.g. md_section README.md "## Manual steps" "### Ubuntu"
md_section() {
    local file="$1"
    shift
    # The headings go through the environment, since awk -v would expand backslashes in them
    HEADINGS="$(printf '%s\t' "$@")" awk -v fence="$MD_FENCE" '
        BEGIN { n = split(ENVIRON["HEADINGS"], want, "\t") - 1 }
        $0 ~ fence { in_code = !in_code }
        !in_code && /^#+ / {
            level = index($0, " ") - 1
            if (depth > 0 && level <= levels[depth]) exit
            if (depth < n && $0 == want[depth + 1]) { levels[++depth] = level; next }
        }
        depth == n {
            if ($0 == "") { if (printed) blanks++; next }
            for (; blanks > 0; blanks--) print ""
            print
            printed = 1
        }
        END { exit !printed }
    ' "$file"
}

# Print a section of a Markdown doc for the terminal, indented, as md_section finds it. Links
# shrink to their text, plus where they point: the URL for a web link, and for a link into the
# repo, the doc's path, as text (see <doc>) (doc_links). The manual-steps steps print their lists
# from the READMEs this way, so the docs are the only copy. Fails when a heading is missing.
# e.g. print_doc_section README.md "## Manual steps" "### Ubuntu"
print_doc_section() {
    local file="$1" text
    shift
    text="$(md_section "$file" "$@")" || {
        echo "  Couldn't find \"$*\" in $file." >&2
        return 1
    }
    printf '%s\n' "$text" | awk '{ print ($0 == "" ? "" : "  " $0) }' | doc_links "$file" | sed -E \
        -e 's/\[([^]]*)\]\((https?:[^)]*)\)/\1 (\2)/g' \
        -e 's/\*\*//g'
}

# Rewrite the links in Markdown text read from stdin that point into the repo, for the terminal:
# [text](<path>#<anchor>) becomes text (see <doc>), with <doc> the path, relative to the repo, of
# the doc it points to, which is the doc the text comes from when the link has only an anchor.
# Web links stay. The repo is DOTFILES_DIR, which lib/common.sh sets.
# Usage: doc_links <doc the text comes from>
doc_links() {
    # Paths go through the environment, since awk -v would expand backslashes in them
    DOC="$1" ROOT="${DOTFILES_DIR:?}" awk '
        # A path with its . and .. parts resolved
        function clean(path, parts, n, i, out, k) {
            n = split(path, parts, "/")
            k = 0
            for (i = 1; i <= n; i++) {
                if (parts[i] == "." || (parts[i] == "" && i > 1)) continue
                if (parts[i] == ".." && k > 1) { k--; continue }
                out[++k] = parts[i]
            }
            path = out[1]
            for (i = 2; i <= k; i++) path = path "/" out[i]
            return path
        }
        BEGIN {
            doc = clean(ENVIRON["DOC"])
            root = clean(ENVIRON["ROOT"])
            dir = doc
            if (!sub(/\/[^\/]*$/, "", dir)) dir = "."
        }
        {
            line = $0
            out = ""
            while (match(line, /\[[^]]*\]\([^)]*\)/)) {
                link = substr(line, RSTART, RLENGTH)
                out = out substr(line, 1, RSTART - 1)
                line = substr(line, RSTART + RLENGTH)
                text = link
                sub(/\]\(.*/, "", text)
                text = substr(text, 2)
                target = link
                sub(/^\[[^]]*\]\(/, "", target)
                sub(/\)$/, "", target)
                if (target ~ /^[a-z]+:/) { out = out link; continue }
                sub(/#.*/, "", target)
                path = target == "" ? doc : clean(dir "/" target)
                if (index(path, root "/") == 1) path = substr(path, length(root) + 2)
                out = out text " (see " path ")"
            }
            print out line
        }
    '
}

# Print the local link targets in a Markdown file: inline links' and reference definitions', less
# any "title" after the target, and none from a code block, which shows a link without making one.
# A target with no ., /, or # is a template's placeholder, such as [PR #123](url).
local_links() {
    awk -v fence="$MD_FENCE" '$0 ~ fence { in_code = !in_code; next }
        in_code { next }
        /^ *\[[^]]+\]:[[:space:]]/ { sub(/^ *\[[^]]+\]:[[:space:]]+/, ""); print; next }
        { line = $0
          while (match(line, /\]\([^)]+\)/)) {
              print substr(line, RSTART + 2, RLENGTH - 3)
              line = substr(line, RSTART + RLENGTH)
          } }' "$1" |
        awk '{ print $1 }' | grep -vE '^(https?|mailto):|^<' | grep -E '[./#]' || true
}

# Print the anchors of a Markdown file's headings, as GitHub makes them: lowercased, punctuation
# dropped, spaces turned into hyphens, and -1, -2, ... added to repeats
anchors() {
    awk -v fence="$MD_FENCE" '$0 ~ fence { in_code = !in_code; next }
        !in_code && /^#+ / {
            a = tolower($0); sub(/^#+ +/, "", a)
            gsub(/[^a-z0-9 _-]/, "", a); gsub(/ /, "-", a)
            print (seen[a]++ ? a "-" seen[a] - 1 : a)
        }' "$1"
}

# Print a line for each local link in a Markdown file that doesn't resolve, down to its #anchor
broken_links() {
    local md="$1" target file anchor
    while IFS= read -r target; do
        file="${target%%#*}"
        anchor=""
        [[ "$target" != *"#"* ]] || anchor="${target#*#}"
        if [ -z "$file" ]; then
            file="$md"
        else
            file="$(dirname "$md")/$file"
        fi
        if [ ! -e "$file" ]; then
            echo "broken link to $target"
        elif [ -n "$anchor" ] && ! anchors "$file" | grep -qxF -- "$anchor"; then
            echo "broken anchor in $target"
        fi
    done < <(local_links "$md")
}
