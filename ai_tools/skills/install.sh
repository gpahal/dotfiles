#!/bin/bash
set -euo pipefail

# Install the repo's skills for Codex and Claude Code.
#
# Install every skill in ai_tools/skills for Codex, as a copy in ~/.agents/skills, and for Claude
# Code, as a link to that copy in ~/.claude/skills. The repo owns both dirs: a run replaces a copy
# that differs from the repo, and deletes every entry that isn't a repo skill, such as a skill
# installed from elsewhere or one the repo no longer has.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"

# Succeeds when Claude Code reads ~/.claude. With CLAUDE_CONFIG_DIR elsewhere, the step installs
# the skills for Codex only, and leaves ~/.claude/skills alone, as the claude-code step does ~/.claude.
claude_skills_on() {
    tool_home_is "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"
}

# Succeeds when a name is safe to use as a directory name under the skills dirs, which the step
# removes with rm -rf. Both agents expect such names anyway.
valid_skill_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]
}

# Print a skill's name: the `name:` field in its SKILL.md frontmatter, without YAML quotes
skill_name() {
    awk '/^---/ { n++; next }
        n == 1 && /^name:/ {
            sub(/^name:[ \t]*/, ""); sub(/[ \t]+$/, "")
            if ($0 ~ /^".*"$/ || $0 ~ /^\047.*\047$/) $0 = substr($0, 2, length($0) - 2)
            print; exit
        }' "$1"
}

# The repo's skills, found once per run by load_repo_skills, sorted by path: each one's name and
# directory
SKILL_NAMES=()
SKILL_DIRS=()

# Fill the arrays above. Fails, naming it, for a skill whose name valid_skill_name rejects, or
# that an earlier skill, by path, already has; that skill is left out, so a name never installs
# one skill over another on alternate runs.
load_repo_skills() {
    local file name result=0 i
    SKILL_NAMES=()
    SKILL_DIRS=()
    while IFS= read -r file; do
        name="$(skill_name "$file")"
        if ! valid_skill_name "$name"; then
            echo "  ${file#"$DOTFILES_DIR"/} names its skill '$name', which isn't lowercase letters, digits, and dashes; skipping it." >&2
            result=1
            continue
        fi
        for i in ${SKILL_NAMES[@]+"${!SKILL_NAMES[@]}"}; do
            [ "${SKILL_NAMES[i]}" == "$name" ] || continue
            echo "  ${file#"$DOTFILES_DIR"/} names the skill '$name', as ${SKILL_DIRS[i]#"$DOTFILES_DIR"/}/SKILL.md does; skipping it." >&2
            result=1
            continue 2
        done
        SKILL_NAMES+=("$name")
        SKILL_DIRS+=("$(dirname "$file")")
    done < <(find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md | LC_ALL=C sort)
    return "$result"
}

# Print a skill dir's executable files, sorted, leaving out what skill_current does
skill_executables() {
    (cd "$1" && find . \( -name __pycache__ -o -name .git \) -prune -o -type f -perm -u+x -print) |
        LC_ALL=C sort
}

# Succeeds when repo skill $1's copy in ~/.agents/skills matches the repo, down to which files are
# executable. A Python cache a skill's script writes, and a .git, don't count.
skill_current() {
    local src="${SKILL_DIRS[$1]}" dest="$AGENTS_SKILLS/${SKILL_NAMES[$1]}"
    [ -d "$dest" ] && [ ! -L "$dest" ] &&
        diff -rq -x __pycache__ -x .git "$src" "$dest" > /dev/null 2>&1 &&
        [ "$(skill_executables "$src")" == "$(skill_executables "$dest")" ]
}

# Succeeds when ~/.claude/skills/<name> is the link to the skill's copy
skill_linked() {
    [ -L "$CLAUDE_SKILLS/$1" ] && [ "$(readlink "$CLAUDE_SKILLS/$1")" == "$AGENTS_SKILLS/$1" ]
}

# Print the skills dirs the step owns: ~/.agents/skills, and ~/.claude/skills with claude_skills_on
skill_dirs() {
    echo "$AGENTS_SKILLS"
    ! claude_skills_on || echo "$CLAUDE_SKILLS"
}

# Print the path of each entry in the skills dirs that isn't a repo skill, one per line
extra_skill_entries() {
    local dir entry
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            case " ${SKILL_NAMES[*]-} " in
                *" $entry "*) ;;
                *) echo "$dir/$entry" ;;
            esac
        done < <(/bin/ls -A "$dir")
    done < <(skill_dirs)
}

# Print a path under HOME as ~/...
shown() {
    # shellcheck disable=SC2088 # shown, not expanded
    printf '%s\n' "~/${1#"$HOME"/}"
}

install_skills() {
    echo "Installing skills..."
    local result=0 changed=false i name dir path
    load_repo_skills || result=1
    # Every entry would count as extra
    if [ ${#SKILL_NAMES[@]} -eq 0 ]; then
        echo "  Found no skills in ai_tools/skills, so left the skills dirs alone." >&2
        return 1
    fi
    claude_skills_on || echo "  CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, but setup assumes ~/.claude, so the skills are for Codex only."
    while IFS= read -r dir; do
        mkdir -p "$dir" || return 1
    done < <(skill_dirs)
    for i in ${SKILL_NAMES[@]+"${!SKILL_NAMES[@]}"}; do
        name="${SKILL_NAMES[i]}"
        if ! skill_current "$i"; then
            changed=true
            if ! rm -rf "${AGENTS_SKILLS:?}/$name" || ! cp -R "${SKILL_DIRS[i]}" "$AGENTS_SKILLS/$name"; then
                echo "  Couldn't copy the $name skill to $(shown "$AGENTS_SKILLS/$name")." >&2
                result=1
                continue
            fi
            echo "  Copied the $name skill to $(shown "$AGENTS_SKILLS/$name")"
        fi
        if claude_skills_on && ! skill_linked "$name"; then
            changed=true
            # ln -sfn would put the link inside a real directory there, rather than replace it
            if ! rm -rf "${CLAUDE_SKILLS:?}/$name" || ! ln -sfn "$AGENTS_SKILLS/$name" "$CLAUDE_SKILLS/$name"; then
                echo "  Couldn't link $(shown "$CLAUDE_SKILLS/$name") to the $name skill." >&2
                result=1
                continue
            fi
            echo "  Linked $(shown "$CLAUDE_SKILLS/$name") to the $name skill"
        fi
    done
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        changed=true
        if rm -rf "$path"; then
            echo "  Removed $(shown "$path"), which isn't a skill in ai_tools/skills"
        else
            echo "  Couldn't remove $(shown "$path")." >&2
            result=1
        fi
    done <<< "$(extra_skill_entries)"
    "$changed" || echo "  Every skill is already installed and up to date."
    return "$result"
}

status() {
    local i name problem path problems=false
    load_repo_skills 2>/dev/null ||
        status_item missing "Skill names in ai_tools/skills: one isn't lowercase letters, digits, and dashes, or two skills share one; run the step to see which"
    claude_skills_on || status_item skipped "Skills for Claude Code: CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, but setup assumes ~/.claude"
    for i in ${SKILL_NAMES[@]+"${!SKILL_NAMES[@]}"}; do
        name="${SKILL_NAMES[i]}"
        problem=""
        if [ ! -d "$AGENTS_SKILLS/$name" ]; then
            problem="not installed"
        elif ! skill_current "$i"; then
            problem="differs from the repo"
        elif claude_skills_on && ! skill_linked "$name"; then
            problem="not linked from ~/.claude/skills"
        fi
        if [ -n "$problem" ]; then
            status_item missing "$name skill, $problem"
            problems=true
        fi
    done
    "$problems" || status_item ok "Every skill in ai_tools/skills, installed and up to date"
    while IFS= read -r path; do
        [ -z "$path" ] ||
            status_item missing "$(shown "$path"), which isn't a skill in ai_tools/skills; the step removes it"
    done <<< "$(extra_skill_entries)"
    status_result
}

apply() {
    install_skills
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
