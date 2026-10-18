# shellcheck shell=bash
# The Markdown link check scripts/check-skills.sh and scripts/check-docs.sh share. It only defines
# functions.

# Print the local link targets in a Markdown file: inline links' and reference definitions', less
# any "title" after the target, and none from a code block, which shows a link without making one.
# A target with no ., /, or # is a template's placeholder, such as [PR #123](url).
local_links() {
    awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next }
        fence { next }
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
    awk '/^```/ { fence = !fence; next }
        !fence && /^#+ / {
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
