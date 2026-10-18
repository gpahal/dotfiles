#!/bin/bash
set -euo pipefail

# Check the skills in ai_tools/skills: each sits at <category>/<skill>/SKILL.md, and every
# <category>/<dir> holds one. Its frontmatter is closed and valid YAML with only the fields
# SKILL_FIELDS lists, names are well formed, unique, and match their directories, and every skill
# has a description of at most 1024 characters and an agents/openai.yaml with an
# interface.display_name, a short_description of 25-64 characters, and only the fields
# OPENAI_YAML_FIELDS lists. user-invocable is true or false and leaves the skill invocable. Its
# invocation agrees across SKILL.md, agents/openai.yaml, and the one heading it's listed under in
# its category README. Links to local files resolve and stay inside the skill or point at another
# skill, the paths a skill names to its own or another skill's files exist (see check_skill_paths),
# scripts/*.sh are executable, no skill holds a symlink, each skill the README's Acknowledgements
# credit has a LICENSE with its source's notice, and the READMEs' links and anchors resolve.
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

# The SKILL.md frontmatter fields Claude Code reads, from its frontmatter reference
# (https://code.claude.com/docs/en/skills, checked 2026-10-10 against Claude Code 2.1.296). Codex
# reads name and description. Claude Code ignores any other field without a warning.
SKILL_FIELDS="name description when_to_use argument-hint arguments disable-model-invocation
user-invocable allowed-tools disallowed-tools model effort context agent background hooks paths
shell metadata license compatibility"
# The agents/openai.yaml fields Codex documents (https://learn.chatgpt.com/docs/build-skills,
# checked 2026-10-10). dependencies.tools entries are a list Codex doesn't define further.
OPENAI_YAML_FIELDS="interface interface.display_name interface.short_description
interface.icon_small interface.icon_large interface.brand_color interface.default_prompt policy
policy.allow_implicit_invocation dependencies dependencies.tools"

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

# Print a key=value line from $yaml_fields, the openai.yaml lines one yq call printed
yaml_field() {
    local line
    while IFS= read -r line; do
        if [ "${line%%=*}" == "$1" ]; then
            printf '%s\n' "${line#*=}"
            return
        fi
    done <<<"$yaml_fields"
}

# The number of characters in UTF-8 text: its bytes but UTF-8's continuation bytes. ${#var}
# counts bytes in the C locale.
char_count() {
    printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}

# in_list <word> <words>: whether a word is one of a space- or newline-separated list
in_list() {
    case " $2 " in *[[:space:]]"$1"[[:space:]]*) return 0 ;; esac
    return 1
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

# Succeeds when a path a skill names exists. ../<skill>/<path> is another skill's, which may be in
# any category, since skills are installed side by side. ai_tools/skills/... starts at the repo's
# top, and any other path at the given directory.
# e.g. skill_path_exists "$skill" references/scope.md
skill_path_exists() {
    local base="$1" path="$2" rest category
    case "$path" in
        ../*)
            rest="${path#../}"
            for category in "$SKILLS_DIR"/*/; do
                if [ -f "$category${rest%%/*}/SKILL.md" ] && [ -e "$category$rest" ]; then
                    return 0
                fi
            done
            return 1
            ;;
        ai_tools/skills/*) [ -e "$SKILLS_DIR/../../$path" ] ;;
        *) [ -e "$base/$path" ] ;;
    esac
}

# Check a relative path a skill's Markdown file names, when its first part is a directory beside
# the file or at the skill's top, such as references/scope.md or, from references/,
# sources/slack.md. Other paths name files in the project the skill works on, such as .scratch/ or
# docs/.
# check_relative_path <skill> <md> <path>
check_relative_path() {
    local skill="$1" md="$2" path="$3" dir first
    case "$path" in
        */*) ;;
        *) return 0 ;;
    esac
    case "$path" in /* | .* | "~"* | ai_tools/* | *[\<\>*\$\{\}]*) return 0 ;; esac
    # Parameter expansion rather than dirname and sed here and below, since this runs for every
    # word in every skill and a fork each took seconds
    dir="${md%/*}"
    first="${path%%/*}"
    if [ -d "$dir/$first" ]; then
        skill_path_exists "$dir" "$path" || fail "$md" "names $path, which doesn't exist"
    elif [ -d "$skill/$first" ]; then
        skill_path_exists "$skill" "$path" || fail "$md" "names $path, which doesn't exist"
    fi
}

# Check the paths a skill's Markdown file names:
# - in backquotes, a path to another skill's file: ../<skill>/<path> or
#   ai_tools/skills/<category>/<skill>/<path>
# - in backquotes outside code fences, and among a code fence's words, a relative path inside the
#   skill (check_relative_path). A backquoted path that's a link's text, or follows "skill's", is
#   left to the other checks.
# - any path under ${CLAUDE_SKILL_DIR}, which is the skill's directory, so
#   ${CLAUDE_SKILL_DIR}/../<skill>/ is another skill's
# Paths with placeholders, shell variables, or globs are skipped.
# shellcheck disable=SC2016 # Markdown's backquotes and ${CLAUDE_SKILL_DIR} in the patterns
check_skill_paths() {
    local skill="$1" md="$2" token path rest
    while IFS= read -r path; do
        path="${path#\`}"
        path="${path%\`}"
        case "$path" in *[\<\>*]*) continue ;; esac
        skill_path_exists "$skill" "$path" ||
            fail "$md" "a path to another skill's file, $path, that doesn't exist"
    done < <(grep -oE '`(\.\./|ai_tools/skills/)[^`[:space:]]+`' "$md" || true)
    while IFS= read -r token; do
        case "$token" in "["* | "skill's "*) continue ;; esac
        path="${token#*\`}"
        path="${path%\`}"
        case "$path" in '${CLAUDE_SKILL_DIR}'*) continue ;; esac
        check_relative_path "$skill" "$md" "$path"
    done < <(awk '/^[[:space:]]*```/ { fence = !fence; next } !fence' "$md" |
        grep -oE "(\[|skill's )?\`[^\`[:space:]]+\`" || true)
    # The words in code fences, less quotes and trailing punctuation
    while IFS= read -r path; do
        check_relative_path "$skill" "$md" "$path"
    done < <(awk '/^[[:space:]]*```/ { fence = !fence; next } fence' "$md" | tr -s '[:blank:]' '\n' |
        sed -E "s/^[\"'(]+//; s/[\"'),;:.]+\$//" | grep -v CLAUDE_SKILL_DIR || true)
    while IFS= read -r path; do
        while :; do
            case "$path" in *[.,\;:]) path="${path%?}" ;; *) break ;; esac
        done
        rest="${path#'${CLAUDE_SKILL_DIR}'/}"
        case "$rest" in *[\<\>*\$\{\}]*) continue ;; esac
        skill_path_exists "$skill" "$rest" || fail "$md" "names $path, which doesn't exist"
    done < <(grep -oE '\$\{CLAUDE_SKILL_DIR\}/[^[:space:]`"'"'"')]+' "$md" || true)
}

# Check that a skill's scripts/*.sh are executable: in git's index when git tracks them, else on
# disk
check_scripts() {
    local script mode
    for script in "$1"/scripts/*.sh; do
        [ -f "$script" ] || continue
        mode="$(git -C "$1" ls-files -s -- "$script" 2>/dev/null | cut -d' ' -f1 || true)"
        if [ -n "$mode" ]; then
            [ "$mode" == 100755 ] || fail "$script" "isn't executable in git. Run: git update-index --chmod=+x $script"
        elif [ ! -x "$script" ]; then
            fail "$script" "isn't executable"
        fi
    done
}

# Print the notice THIRD_PARTY_LICENSES holds for a source URL: the lines after its "For skills
# from ... (<url>):" line and a blank line, up to the next ---, less trailing blank lines
source_notice() {
    awk -v url="$1" '/^For skills from / && index($0, "(" url "):") { on = 1; getline; next }
        on && /^---$/ { exit }
        on { line[++n] = $0 }
        END { while (n > 0 && line[n] == "") n--; for (i = 1; i <= n; i++) print line[i] }' \
        "$SKILLS_DIR/THIRD_PARTY_LICENSES"
}

# Print "<url> <skill>" for each skill the README's Acknowledgements credit to a source, from each
# bullet's first link and the names after its last ": ", less any "(upstream ...)"
credited_skills() {
    awk '/^## / { on = ($0 == "## Acknowledgements"); next }
        on && /^- / { if (b != "") print b; b = $0; next }
        on && b != "" && /^  / { sub(/^ +/, " "); b = b $0; next }
        on && b != "" { print b; b = "" }
        END { if (b != "") print b }' "$SKILLS_DIR/README.md" |
        while IFS= read -r bullet; do
            url="${bullet#*](}"
            url="${url%%)*}"
            printf '%s\n' "${bullet##*: }" | sed -E 's/ \([^)]*\)//g; s/,? and /, /g' | tr ',' '\n' |
                sed -E 's/^ +//; s/ +$//' | sed '/^$/d' | sed "s|^|$url |"
        done
}

# Check a skill's LICENSE against the source the Acknowledgements credit it to, if any. Its first
# line names the source URL, and the rest is that source's notice.
check_license() {
    local dir="$1" name url credited license="$1/LICENSE"
    name="$(basename "$dir")"
    credited="$(printf '%s\n' "$credits" | awk -v name="$name" '$2 == name { print $1; exit }')"
    if [ ! -f "$license" ]; then
        [ -z "$credited" ] || fail "$dir" "no LICENSE, though the README's Acknowledgements credit $name to $credited"
        return 0
    fi
    url="$(head -n 1 "$license" | grep -oE 'https://[^ ,)]+' | head -n 1 || true)"
    if [ -z "$credited" ]; then
        fail "$license" "the README's Acknowledgements don't credit $name to a source"
    elif [ "$url" != "$credited" ]; then
        fail "$license" "names ${url:-no source URL}, but the README's Acknowledgements credit $name to $credited"
    elif [ -z "$(source_notice "$url")" ] || [ "$(tail -n +3 "$license")" != "$(source_notice "$url")" ]; then
        fail "$license" "doesn't match the notice for $url in THIRD_PARTY_LICENSES"
    fi
}

credits="$(credited_skills)"
names=""
while IFS= read -r skill_md; do
    dir="$(dirname "$skill_md")"
    if ! [[ "${skill_md#"$SKILLS_DIR"/}" =~ ^[^/]+/[^/]+/SKILL\.md$ ]]; then
        fail "$skill_md" "isn't at <category>/<skill>/SKILL.md, where the installer looks"
        continue
    fi
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
    if [ -z "$name" ]; then
        fail "$skill_md" "no name in the frontmatter"
    elif [ "$name" != "$(basename "$dir")" ]; then
        fail "$skill_md" "the name \"$name\" differs from the directory name \"$(basename "$dir")\""
    elif ! [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || [ ${#name} -gt 64 ]; then
        fail "$skill_md" "the name \"$name\" isn't at most 64 lowercase letters, digits, and single hyphens between them"
    fi
    names="$names$name"$'\n'
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        in_list "$key" "$SKILL_FIELDS" ||
            fail "$skill_md" "the frontmatter has $key, which isn't a SKILL.md field"
    done < <(printf '%s\n' "$fields" | sed 's/=.*//')
    # user-invocable: false hides the skill from the / menu but leaves the model free to load it.
    # Codex has no such field, so it doesn't bear on openai.yaml or the README's heading.
    user_invocable="$(field user-invocable)"
    case "$user_invocable" in
        "" | true) ;;
        false)
            [ "$(field disable-model-invocation)" != true ] ||
                fail "$skill_md" "user-invocable: false and disable-model-invocation: true, so nothing can invoke it"
            ;;
        *) fail "$skill_md" "user-invocable is $user_invocable, not true or false" ;;
    esac
    if ! [[ "$(field description)" =~ [^[:space:]] ]]; then
        fail "$skill_md" "no description in the frontmatter"
    elif [ "$description_length" -gt 1024 ]; then
        fail "$skill_md" "the description is $description_length characters, over 1024"
    fi

    if [ "$(field disable-model-invocation)" == true ]; then
        want=User-invoked
    else
        want=Model-invoked
    fi
    yaml="$dir/agents/openai.yaml"
    if [ ! -f "$yaml" ]; then
        fail "$dir" "no agents/openai.yaml"
    elif ! yaml_fields="$(yq '"implicit=" + (.policy.allow_implicit_invocation | tostring),
            "display_name=" + (.interface.display_name | tostring),
            "short_description=" + (.interface.short_description | tostring),
            (.. | path | select(length == 1 or length == 2) | "key=" + join("."))' "$yaml" 2>&1)"; then
        fail "$yaml" "isn't valid YAML: $yaml_fields"
    else
        implicit="$(yaml_field implicit)"
        [ "$implicit" != null ] || implicit=""
        for key in display_name short_description; do
            value="$(yaml_field "$key")"
            [ "$value" != null ] && [[ "$value" =~ [^[:space:]] ]] || fail "$yaml" "no interface.$key"
        done
        short="$(yaml_field short_description)"
        short_length="$(char_count "$short")"
        if [ "$short" != null ] && [[ "$short" =~ [^[:space:]] ]] &&
            { [ "$short_length" -lt 25 ] || [ "$short_length" -gt 64 ]; }; then
            fail "$yaml" "interface.short_description is $short_length characters, not 25-64"
        fi
        # The keys one and two levels down, joined by dots
        while IFS= read -r key; do
            [ -n "$key" ] || continue
            in_list "$key" "$OPENAI_YAML_FIELDS" ||
                fail "$yaml" "$key isn't an openai.yaml field"
        done < <(printf '%s\n' "$yaml_fields" | sed -n 's/^key=//p')
        if [ -z "$implicit" ] && grep -q allow_implicit_invocation "$yaml"; then
            fail "$yaml" "allow_implicit_invocation is outside policy:, where Codex ignores it"
        elif [ "$implicit" == false ]; then
            [ "$want" == User-invoked ] || fail "$yaml" "allow_implicit_invocation is false, but SKILL.md has no disable-model-invocation: true"
        else
            [ "$want" == Model-invoked ] || fail "$yaml" "SKILL.md has disable-model-invocation: true, but policy.allow_implicit_invocation isn't false"
        fi
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
    check_scripts "$dir"
    check_license "$dir"
    # The skills CLI copies a symlink's target, so the step's check would never find a match
    while IFS= read -r link; do
        fail "$link" "a symlink, which the installed copy would hold as a file. Copy the file instead."
    done < <(find "$dir" -type l)

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
        check_skill_paths "$dir" "$md"
    done < <(find "$dir" -name '*.md')
done < <(find "$SKILLS_DIR" -name SKILL.md | sort)

# A directory in a category with no SKILL.md is no skill to the installer, so its files never install
for dir in "$SKILLS_DIR"/*/*/; do
    [ -f "$dir/SKILL.md" ] || fail "${dir%/}" "no SKILL.md, so the installer skips this directory"
done

while IFS= read -r readme; do
    while IFS= read -r problem; do
        fail "$readme" "$problem"
    done < <(broken_links "$readme")
done < <(find "$SKILLS_DIR" -maxdepth 2 -name README.md | sort)

while read -r _ name; do
    [ -n "$name" ] || continue
    printf '%s' "$names" | grep -qxF -- "$name" ||
        fail "$SKILLS_DIR/README.md" "the Acknowledgements credit $name, which isn't a skill here"
done <<<"$credits"

duplicates="$(printf '%s' "$names" | sort | uniq -d)"
[ -z "$duplicates" ] || fail "$SKILLS_DIR" "skill names used twice: $(echo "$duplicates" | tr '\n' ' ')"

[ "$errors" -eq 0 ] || exit 1
