# Markdown sections and local links for the docs and skills checks. Source it; don't run it.
# shellcheck shell=bash

# Code fence; every reader skips code blocks so a # line or link in one doesn't count.
MD_FENCE='^[[:space:]]*(```|~~~)'

# Print the section under nested headings, trimmed. Fails when a heading is missing or the section is empty.
# e.g. md_section README.md "## Manual steps" "### Ubuntu"
md_section() {
    local file="$1"
    shift
    # Via the environment, since awk -v expands backslashes
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

# Print md_section indented for the terminal, with links as plain text.
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

# Rewrite repo links on stdin as "text (see <repo-relative path>)"; web links stay.
# Usage: doc_links <doc the text comes from>
doc_links() {
    # Via the environment, since awk -v expands backslashes
    DOC="$1" ROOT="${DOTFILES_DIR:?}" awk '
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

# Print local link targets. A target with no ., /, or # is a placeholder, such as [PR #123](url).
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

# Heading anchors as GitHub makes them
anchors() {
    awk -v fence="$MD_FENCE" '$0 ~ fence { in_code = !in_code; next }
        !in_code && /^#+ / {
            a = tolower($0); sub(/^#+ +/, "", a)
            gsub(/[^a-z0-9 _-]/, "", a); gsub(/ /, "-", a)
            print (seen[a]++ ? a "-" seen[a] - 1 : a)
        }' "$1"
}

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
