#!/bin/bash
set -euo pipefail

# Check each skill's frontmatter, agents/openai.yaml, invocation across files and README, and links.

SCRIPTS_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd "$SCRIPTS_DIR/../ai_tools/skills" && pwd)"
# shellcheck source=lib/markdown.sh
source "$SCRIPTS_DIR/lib/markdown.sh"
# shellcheck source=lib/check.sh
source "$SCRIPTS_DIR/lib/check.sh"

# Ubuntu's apt yq is a different tool, with another syntax
if ! yq --version 2>/dev/null | grep -q mikefarah; then
    echo "check-skills.sh needs yq from https://github.com/mikefarah/yq. Install it with: brew install yq" >&2
    exit 1
fi

# fail_in <file> <problem>
fail_in() {
    fail "${1#"$SKILLS_DIR"/}: $2"
}

# Fails when line 1 isn't --- or nothing closes it.
frontmatter_text() {
    awk 'NR == 1 { if ($0 !~ /^---[ \t]*$/) exit 1; next }
        /^---[ \t]*$/ { closed = 1; exit }
        { print }
        END { exit !closed }' "$1"
}

# Read a field from $fields (key=<JSON> lines); strips a string's quotes but not its escapes.
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

# Keeps leading ..s
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

readme_headings() {
    awk -v link="](./$2/SKILL.md)" '/^## / { heading = substr($0, 4) }
        { s = $0; while ((i = index(s, link)) > 0) { print heading; s = substr(s, i + length(link)) } }' "$1"
}

while IFS= read -r skill_md; do
    dir="$(dirname "$skill_md")"
    if ! fm="$(frontmatter_text "$skill_md")"; then
        fail_in "$skill_md" "no frontmatter closed by ---"
        continue
    fi
    if ! yaml_error="$(printf '%s\n' "$fm" | yq -e 'tag == "!!map"' 2>&1 >/dev/null)"; then
        fail_in "$skill_md" "the frontmatter isn't a YAML mapping${yaml_error:+: $yaml_error}"
        continue
    fi
    # yq's length counts bytes; split("") counts characters.
    fields="$(printf '%s\n' "$fm" |
        yq '(.description // "" | tostring | split("") | length), (to_entries | .[] | .key + "=" + (.value | @json))')"
    description_length="${fields%%$'\n'*}"
    case "$fields" in *$'\n'*) fields="${fields#*$'\n'}" ;; *) fields="" ;; esac
    name="$(field name)"
    if [ "$name" != "$(basename "$dir")" ]; then
        fail_in "$skill_md" "the name \"$name\" differs from the directory name \"$(basename "$dir")\""
    fi
    if ! [[ "$(field description)" =~ [^[:space:]] ]]; then
        fail_in "$skill_md" "no description in the frontmatter"
    elif [ "$description_length" -gt 1024 ]; then
        fail_in "$skill_md" "the description is $description_length characters, over 1024"
    fi

    if [ "$(field disable-model-invocation)" == true ]; then
        want=User-invoked
    else
        want=Model-invoked
    fi
    yaml="$dir/agents/openai.yaml"
    if [ ! -f "$yaml" ]; then
        fail_in "$dir" "no agents/openai.yaml"
    elif ! implicit="$(yq '.policy.allow_implicit_invocation' "$yaml" 2>&1)"; then
        fail_in "$yaml" "isn't valid YAML: $implicit"
    elif [ "$implicit" == false ]; then
        [ "$want" == User-invoked ] || fail_in "$yaml" "allow_implicit_invocation is false, but SKILL.md has no disable-model-invocation: true"
    else
        [ "$want" == Model-invoked ] || fail_in "$yaml" "SKILL.md has disable-model-invocation: true, but policy.allow_implicit_invocation isn't false"
    fi
    readme="$(dirname "$dir")/README.md"
    if [ ! -f "$readme" ]; then
        fail_in "$readme" "is missing, so nothing lists $(basename "$dir")"
    else
        headings="$(readme_headings "$readme" "$(basename "$dir")")"
        if [ -z "$headings" ]; then
            fail_in "$readme" "doesn't list $(basename "$dir"), under \"$want\""
        elif [ "$(printf '%s\n' "$headings" | wc -l | tr -d ' ')" -gt 1 ]; then
            fail_in "$readme" "lists $(basename "$dir") more than once, under: $(printf '%s\n' "$headings" | paste -sd, - | sed 's/,/, /g')"
        elif [ "$headings" != "$want" ]; then
            fail_in "$readme" "lists $(basename "$dir") under \"$headings\", not \"$want\""
        fi
    fi

    # Skills install side by side, not in categories, so a link may leave the skill only for another skill.
    while IFS= read -r md; do
        md_dir="$(dirname "$md")"
        while IFS= read -r target; do
            target="${target%%#*}"
            [ -n "$target" ] || continue
            if [ ! -e "$md_dir/$target" ]; then
                fail_in "$md" "broken link to $target"
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
            ! "$outside" || fail_in "$md" "a link outside the skill to $target, which breaks once installed"
        done < <(local_links "$md")
    done < <(find "$dir" -name '*.md')
done < <(find "$SKILLS_DIR" -mindepth 3 -maxdepth 3 -name SKILL.md | sort)

while IFS= read -r readme; do
    while IFS= read -r problem; do
        fail_in "$readme" "$problem"
    done < <(broken_links "$readme")
done < <(find "$SKILLS_DIR" -maxdepth 2 -name README.md | sort)

[ "$errors" -eq 0 ] || exit 1
