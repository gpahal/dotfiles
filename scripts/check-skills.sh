#!/bin/bash
set -euo pipefail

# Check the skills in ai_tools/skills: each <category>/<skill>/SKILL.md has closed frontmatter that
# is a YAML mapping, a name equal to its directory's, and a description of at most 1024 characters,
# and its skill has an agents/openai.yaml. Its invocation agrees across SKILL.md, agents/openai.yaml,
# and the one heading it's listed under in its category README. Links to local files resolve, and
# stay inside the skill or point at another skill, and the READMEs' links and anchors resolve.
# Needs mikefarah's yq. `just check` runs it.

SKILLS_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../ai_tools/skills" && pwd)"
# shellcheck source=lib/markdown.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/markdown.sh"
errors=0

# Ubuntu's apt yq is a different tool, with another syntax
if ! yq --version 2>/dev/null | grep -q mikefarah; then
    echo "check-skills.sh needs yq from https://github.com/mikefarah/yq. Install it with: brew install yq" >&2
    exit 1
fi

fail() {
    echo "${1#"$SKILLS_DIR"/}: $2" >&2
    errors=$((errors + 1))
}

# Print the frontmatter of a SKILL.md: the lines between a first line of --- and the next ---.
# Fails when the first line isn't --- or nothing closes it.
frontmatter_text() {
    awk 'NR == 1 { if ($0 !~ /^---[ \t]*$/) exit 1; next }
        /^---[ \t]*$/ { closed = 1; exit }
        { print }
        END { exit !closed }' "$1"
}

# Print a field from $fields, the frontmatter's key=<JSON value> lines, or nothing when it's
# missing or null. A string loses its quotes, and its escapes stay.
field() {
    local line value=""
    while IFS= read -r line; do
        if [ "${line%%=*}" == "$1" ]; then
            value="${line#*=}"
            break
        fi
    done <<<"$fields"
    [ "$value" != null ] || value=""
    value="${value#\"}"
    printf '%s\n' "${value%\"}"
}

# Print a relative path with its . and .. parts resolved, keeping the leading ..s
normalize_path() {
    local part parts norm=""
    IFS=/ read -ra parts <<<"$1"
    for part in ${parts[@]+"${parts[@]}"}; do
        case "$part" in
            "" | .) ;;
            ..)
                if [ -n "$norm" ] && [ "${norm##*/}" != .. ]; then
                    case "$norm" in */*) norm="${norm%/*}" ;; *) norm="" ;; esac
                else
                    norm="${norm:+$norm/}.."
                fi
                ;;
            *) norm="${norm:+$norm/}$part" ;;
        esac
    done
    printf '%s\n' "$norm"
}

# Print the heading of the README section of each link to a skill's SKILL.md, one per link
readme_headings() {
    awk -v link="](./$2/SKILL.md)" '/^## / { heading = substr($0, 4) }
        { s = $0; while ((i = index(s, link)) > 0) { print heading; s = substr(s, i + length(link)) } }' "$1"
}

while IFS= read -r skill_md; do
    dir="$(dirname "$skill_md")"
    if ! fm="$(frontmatter_text "$skill_md")"; then
        fail "$skill_md" "no frontmatter closed by ---"
        continue
    fi
    if ! yaml_error="$(printf '%s\n' "$fm" | yq -e 'tag == "!!map"' 2>&1 >/dev/null)"; then
        fail "$skill_md" "the frontmatter isn't a YAML mapping${yaml_error:+: $yaml_error}"
        continue
    fi
    # The description's decoded length in characters, then a key=<JSON value> line per field. yq's
    # length counts bytes, but split("") splits a string into its characters.
    fields="$(printf '%s\n' "$fm" |
        yq '(.description // "" | tostring | split("") | length), (to_entries | .[] | .key + "=" + (.value | @json))')"
    description_length="${fields%%$'\n'*}"
    case "$fields" in *$'\n'*) fields="${fields#*$'\n'}" ;; *) fields="" ;; esac
    name="$(field name)"
    if [ "$name" != "$(basename "$dir")" ]; then
        fail "$skill_md" "the name \"$name\" differs from the directory name \"$(basename "$dir")\""
    fi
    if ! [[ "$(field description)" =~ [^[:space:]] ]]; then
        fail "$skill_md" "no description in the frontmatter"
    elif [ "$description_length" -gt 1024 ]; then
        fail "$skill_md" "the description is $description_length characters, over 1024"
    fi

    # The invocation: SKILL.md's disable-model-invocation, openai.yaml's
    # policy.allow_implicit_invocation, and the category README's heading agree
    if [ "$(field disable-model-invocation)" == true ]; then
        want=User-invoked
    else
        want=Model-invoked
    fi
    yaml="$dir/agents/openai.yaml"
    if [ ! -f "$yaml" ]; then
        fail "$dir" "no agents/openai.yaml"
    elif ! implicit="$(yq '.policy.allow_implicit_invocation' "$yaml" 2>&1)"; then
        fail "$yaml" "isn't valid YAML: $implicit"
    elif [ "$implicit" == false ]; then
        [ "$want" == User-invoked ] || fail "$yaml" "allow_implicit_invocation is false, but SKILL.md has no disable-model-invocation: true"
    else
        [ "$want" == Model-invoked ] || fail "$yaml" "SKILL.md has disable-model-invocation: true, but policy.allow_implicit_invocation isn't false"
    fi
    readme="$(dirname "$dir")/README.md"
    if [ ! -f "$readme" ]; then
        fail "$readme" "is missing, so nothing lists $(basename "$dir")"
    else
        headings="$(readme_headings "$readme" "$(basename "$dir")")"
        if [ -z "$headings" ]; then
            fail "$readme" "doesn't list $(basename "$dir"), under \"$want\""
        elif [ "$(printf '%s\n' "$headings" | wc -l | tr -d ' ')" -gt 1 ]; then
            fail "$readme" "lists $(basename "$dir") more than once, under: $(printf '%s\n' "$headings" | paste -sd, - | sed 's/,/, /g')"
        elif [ "$headings" != "$want" ]; then
            fail "$readme" "lists $(basename "$dir") under \"$headings\", not \"$want\""
        fi
    fi

    # Markdown links to local files, from every .md file in the skill. Skills are installed side by
    # side, not in their categories, so a link may leave the skill only for another skill's dir.
    while IFS= read -r md; do
        md_dir="$(dirname "$md")"
        while IFS= read -r target; do
            target="${target%%#*}"
            [ -n "$target" ] || continue
            if [ ! -e "$md_dir/$target" ]; then
                fail "$md" "broken link to $target"
                continue
            fi
            path="$(normalize_path "${md_dir#"$dir"}/$target")"
            case "$path" in
                ../../* | ..) outside=true ;;
                ../*)
                    other="${path#../}"
                    outside=true
                    [ ! -f "$(dirname "$dir")/${other%%/*}/SKILL.md" ] || outside=false
                    ;;
                *) outside=false ;;
            esac
            ! "$outside" || fail "$md" "a link outside the skill to $target, which breaks once installed"
        done < <(local_links "$md")
    done < <(find "$dir" -name '*.md')
done < <(find "$SKILLS_DIR" -mindepth 3 -maxdepth 3 -name SKILL.md | sort)

while IFS= read -r readme; do
    while IFS= read -r problem; do
        fail "$readme" "$problem"
    done < <(broken_links "$readme")
done < <(find "$SKILLS_DIR" -maxdepth 2 -name README.md | sort)

[ "$errors" -eq 0 ] || exit 1
