#!/bin/bash
set -euo pipefail

# Install every skill in ai_tools/skills globally, for Claude Code and Codex, and offer to remove
# the ones this repo installed before but no longer has. A copy edited by hand is backed up before
# it's replaced.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=lib/hash.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hash.sh"

# Pinned so a new release can't change what setup does. Bump it deliberately, after checking the
# add and remove flags below against `npx skills@<version> --help`, and the Node.js version and
# SKILLS_CLI_EXCLUDES below.
SKILLS_CLI="skills@1.7.1"
# The oldest Node.js major version setup runs it with. Its `engines` field
# (`npm view skills@<version> engines`) allows 22.20, but setup asks for 24, the LTS the runtimes
# step installs.
SKILLS_CLI_NODE_MAJOR=24
# What the skills CLI leaves out of its copies, as a find expression: EXCLUDE_FILES and
# EXCLUDE_DIRS in its src/installer.ts. Every check here leaves out the same, so metadata or a
# Python cache in the source, or a cache a skill's script wrote into its installed copy, isn't a
# difference. Check it when bumping SKILLS_CLI.
SKILLS_CLI_EXCLUDES=(-name metadata.json -o -type d \( -name .git -o -name __pycache__ -o -name __pypackages__ \))

# The skills this repo installed, one "<hash>  <name>" line each. Only these are ever offered for
# removal, so skills added from elsewhere are left alone. The hash is the skill_sha256 of the copy
# in ~/.agents/skills when it last matched the repo, so a copy edited by hand since can be backed
# up before it's replaced, or - when none is known.
SKILLS_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/installed-skills"
# Where those backups go. Not into a skills dir, where agents would load them as skills.
SKILLS_BACKUP_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/skills-backup"

# Succeeds when Claude Code reads ~/.claude. With CLAUDE_CONFIG_DIR elsewhere, the step installs
# the skills for Codex only, and leaves ~/.claude/skills alone, as the claude-code step does ~/.claude.
claude_skills_on() {
    tool_home_is "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"
}

# Print the skills CLI's --agent values, one per line
skill_agents() {
    ! claude_skills_on || echo claude-code
    echo codex
}

# Succeeds when a name is safe to use as a directory name under the skills dirs, which the step
# removes with rm -rf. The skills CLI and both agents expect such names anyway.
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
# directory, and its skill_sha256 once something needs it. SKILL_PROBLEM holds what check_skill
# found last.
SKILL_NAMES=()
SKILL_DIRS=()
SKILL_HASHES=()
SKILL_PROBLEM=()

# Fill the arrays above. Fails, naming it, for a skill whose name valid_skill_name rejects, or
# that an earlier skill, by path, already has; that skill is left out, so a name never installs
# one skill over another on alternate runs.
load_repo_skills() {
    local file name result=0 i
    SKILL_NAMES=()
    SKILL_DIRS=()
    SKILL_HASHES=()
    SKILL_PROBLEM=()
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
        SKILL_HASHES+=("")
        SKILL_PROBLEM+=("")
    done < <(find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md | LC_ALL=C sort)
    return "$result"
}

# Print the repo's skill names, sorted
repo_skill_names() {
    [ "${#SKILL_NAMES[@]}" -eq 0 ] || printf '%s\n' "${SKILL_NAMES[@]}" | LC_ALL=C sort -u
}

# Print the dir_sha256 of a skill's directory, leaving out what the skills CLI doesn't copy
skill_sha256() {
    dir_sha256 "$1" "${SKILLS_CLI_EXCLUDES[@]}"
}

# Print the hash of repo skill $1, hashing it the first time
repo_skill_hash() {
    if [ -z "${SKILL_HASHES[$1]}" ]; then
        SKILL_HASHES[$1]="$(skill_sha256 "${SKILL_DIRS[$1]}")" || return 1
    fi
    printf '%s\n' "${SKILL_HASHES[$1]}"
}

# Set SKILL_PROBLEM[$1] to why repo skill $1 needs adding again: "not installed" or "out of
# date", or to nothing when it's installed for both agents and matches the repo, down to which
# files are executable. Claude Code's copy must be the skills CLI's link to the Codex copy, so a
# stale directory or a link to another copy counts as out of date. Runs in this shell, not a
# command substitution, so the repo hash it takes is kept.
check_skill() {
    local i="$1" installed="$HOME/.agents/skills/${SKILL_NAMES[$1]}" resolved want
    SKILL_PROBLEM[i]=""
    # Hashed first, in this shell, so the hash is kept for the rest of the run
    repo_skill_hash "$i" > /dev/null || true
    want="${SKILL_HASHES[i]}"
    # -d first: GNU and uutils realpath, unlike macOS's, succeed when only the last part is missing
    if [ ! -d "$installed" ] || ! resolved="$(realpath "$installed" 2>/dev/null)"; then
        SKILL_PROBLEM[i]="not installed"
    elif ! { { ! claude_skills_on || [ "$(realpath "$HOME/.claude/skills/${SKILL_NAMES[i]}" 2>/dev/null)" = "$resolved" ]; } &&
        [ -n "$want" ] && [ "$(skill_sha256 "$installed" 2>/dev/null)" = "$want" ]; }; then
        SKILL_PROBLEM[i]="out of date"
    fi
}

# Run check_skill on every repo skill
check_skills() {
    local i
    for i in ${SKILL_NAMES[@]+"${!SKILL_NAMES[@]}"}; do
        check_skill "$i"
    done
}

# Print the index of each repo skill check_skills found a problem with
problem_skills() {
    local i
    for i in ${SKILL_NAMES[@]+"${!SKILL_NAMES[@]}"}; do
        [ -z "${SKILL_PROBLEM[i]}" ] || echo "$i"
    done
}

# Run the pinned skills CLI with the given arguments, which name any path absolutely. npm exec
# prefers a matching skills package in the working directory's project, and reads that project's
# .npmrc, so running setup from inside a project could run the project's code. So the CLI runs
# from a temp dir that holds an empty package.json, which makes the dir its own project. Without
# it, npm would look for the project in the dir's parents, such as a /tmp any user can write to.
# DO_NOT_TRACK turns off its telemetry.
skills_cli() {
    local dir result=0
    dir="$(mktemp -d)" || return 1
    echo '{}' > "$dir/package.json" &&
        (cd "$dir" && DO_NOT_TRACK=1 npx -y "$SKILLS_CLI" "$@") ||
        result=$?
    rm -rf "$dir"
    return "$result"
}

# Succeeds when node is at least SKILLS_CLI_NODE_MAJOR
node_new_enough() {
    local major
    major="$(node --version 2>/dev/null)" || return 1
    major="${major#v}"
    major="${major%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge "$SKILLS_CLI_NODE_MAJOR" ]
}

# Print the names SKILLS_STATE records, sorted, leaving out any valid_skill_name rejects
recorded_skill_names() {
    [ -s "$SKILLS_STATE" ] || return 0
    awk '{ print $2 }' "$SKILLS_STATE" | while IFS= read -r name; do
        ! valid_skill_name "$name" || echo "$name"
    done | LC_ALL=C sort -u
}

# Print the hash SKILLS_STATE records for a skill, or nothing
recorded_skill_hash() {
    [ -f "$SKILLS_STATE" ] || return 0
    awk -v name="$1" '$2 == name && $1 != "-" { print $1; exit }' "$SKILLS_STATE"
}

# Copy a skill's installed dir to SKILLS_BACKUP_DIR/<label>.<timestamp>, adding -2, -3, ... rather
# than overwrite an older backup
backup_skill_dir() {
    local dir="$1" base bak n=1
    base="$SKILLS_BACKUP_DIR/$2.$(date +%Y%m%d-%H%M%S)"
    bak="$base"
    while [ -e "$bak" ]; do
        n=$((n + 1))
        bak="$base-$n"
    done
    if mkdir -p "$bak" && cp -Rp "$dir/." "$bak"; then
        echo "  Backed up $dir to $bak"
        return 0
    fi
    echo "  Couldn't back up $dir to $bak, so left it unchanged." >&2
    return 1
}

# Before the add replaces repo skill $1's installed copy, back up what was edited by hand: the copy
# in ~/.agents/skills when it matches neither the repo nor the hash recorded when setup installed
# it, and a real directory at ~/.claude/skills/<name>, where the CLI puts a link, unless it matches
# the repo. --backup or --no-backup (DOTFILES_BACKUP) decides; otherwise ask with a terminal, and
# back up without one, as copy_file does. Fails when a backup does, so the add skips the skill.
backup_edited_skill() {
    local name="${SKILL_NAMES[$1]}"
    local agents="$HOME/.agents/skills/$name" claude="$HOME/.claude/skills/$name"
    local repo_hash hash dir label edited=()
    repo_hash="$(repo_skill_hash "$1")" || return 1
    if [ -d "$agents" ]; then
        hash="$(skill_sha256 "$agents" 2>/dev/null)" || return 1
        if [ "$hash" != "$repo_hash" ] && [ "$hash" != "$(recorded_skill_hash "$name")" ]; then
            edited+=("$agents")
        fi
    fi
    if claude_skills_on && [ -d "$claude" ] && [ ! -L "$claude" ]; then
        hash="$(skill_sha256 "$claude" 2>/dev/null)" || return 1
        [ "$hash" == "$repo_hash" ] || edited+=("$claude")
    fi
    for dir in ${edited[@]+"${edited[@]}"}; do
        case "${DOTFILES_BACKUP:-}" in
            no) continue ;;
            yes) ;;
            *)
                if is_interactive &&
                    ! confirm "  $dir differs from what setup installed. Back it up to $SKILLS_BACKUP_DIR?"; then
                    continue
                fi
                ;;
        esac
        label="$name"
        [ "$dir" != "$claude" ] || label="$name.claude"
        backup_skill_dir "$dir" "$label" || return 1
    done
}

# Add the repo skills check_skills found a problem with, backing up edited copies first. A skill
# whose backup fails is left out, so its edits survive. Fails with 1 when the add fails or leaves a
# copy it should have made wrong, and with 2 when only a backup failed.
add_skills() {
    local i add=() held="" result=0 agent agents=()
    while IFS= read -r agent; do agents+=("$agent"); done < <(skill_agents)
    # Read on fd 3, so backup_edited_skill's confirm reads the terminal, not this list
    while IFS= read -r i <&3; do
        if backup_edited_skill "$i"; then
            add+=("${SKILL_NAMES[i]}")
        else
            held="$held ${SKILL_NAMES[i]}"
        fi
    done 3< <(problem_skills)
    if [ -n "$held" ]; then
        echo "  Didn't add these skills, since their edited copies couldn't be backed up:$held" >&2
        result=2
    fi
    [ "${#add[@]}" -gt 0 ] || return "$result"
    # The skills CLI (https://skills.sh) copies the skills into ~/.agents/skills (Codex) and
    # symlinks them into ~/.claude/skills (Claude Code).
    if ! skills_cli add "$DOTFILES_DIR/ai_tools/skills" \
        --global --agent "${agents[@]}" --skill "${add[@]}" --yes; then
        echo "  The skills CLI failed to add the skills." >&2
        result=1
    fi
    # The CLI can exit zero after a per-skill copy failure. Verify every requested copy.
    for i in $(problem_skills); do
        [[ " $held " != *" ${SKILL_NAMES[i]} "* ]] || continue
        check_skill "$i"
        if [ -n "${SKILL_PROBLEM[i]}" ]; then
            echo "  ${SKILL_NAMES[i]} wasn't installed correctly: ${SKILL_PROBLEM[i]}" >&2
            result=1
        fi
    done
    return "$result"
}

install_skills() {
    echo "Installing skills..."
    if ! command -v npx &>/dev/null; then
        echo "  npx not found. Install Node.js with bash setup.sh runtimes, then re-run." >&2
        return 1
    fi
    if ! node_new_enough; then
        echo "  The skills step needs Node.js $SKILLS_CLI_NODE_MAJOR or newer, not" \
            "$(node --version 2>/dev/null || echo none)." >&2
        echo "  Upgrade Node.js with bash setup.sh runtimes, then re-run." >&2
        return 1
    fi
    local result=0 add_ok=true add_status=0
    load_repo_skills || result=1
    claude_skills_on || echo "  CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, but setup assumes ~/.claude, so the skills are for Codex only."
    check_skills
    if [ -z "$(problem_skills)" ]; then
        echo "  Every skill is already installed and up to date."
    else
        add_skills || add_status=$?
        case "$add_status" in
            0) ;;
            2) result=1 ;;
            *) add_ok=false ;;
        esac
    fi
    # Stale skills don't depend on the add, so remove them even when it failed
    remove_stale_skills "$add_ok" || result=1
    "$add_ok" || return 1
    return "$result"
}

# Print what's left of the named skill in either agent's skills dir
skill_leftovers() {
    local dir dirs=("$HOME/.agents/skills/$1")
    ! claude_skills_on || dirs+=("$HOME/.claude/skills/$1")
    for dir in "${dirs[@]}"; do
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            echo "$dir"
        fi
    done
}

# Succeeds when anything of the named skill is left in either agent's skills dir. The skills CLI
# keeps the files in ~/.agents/skills and links them from ~/.claude/skills, so a dangling link
# counts too.
skill_installed() {
    [ -n "$(skill_leftovers "$1")" ]
}

# Print the skills SKILLS_STATE lists that the repo no longer has
stale_skill_names() {
    recorded_skill_names | LC_ALL=C comm -13 <(repo_skill_names) -
}

# Remove a stale skill for every agent. Fails, printing what's left, when the skills CLI fails or
# anything of the skill is left.
remove_skill() {
    local name="$1" agent agents=()
    while IFS= read -r agent; do agents+=("$agent"); done < <(skill_agents)
    if ! skills_cli remove --global --agent "${agents[@]}" --yes "$name"; then
        # Left as the CLI left it, so its lock file still agrees and the next run retries
        echo "  The skills CLI failed to remove the $name skill." >&2
        return 1
    fi
    # The CLI keeps the shared copy in ~/.agents/skills while another agent it knows, such as
    # Zed or Cursor, is installed. Codex reads that copy too, whatever --agent says, so remove it.
    rm -rf "$HOME/.agents/skills/$name"
    ! claude_skills_on || rm -rf "$HOME/.claude/skills/$name"
    if skill_installed "$name"; then
        echo "  Couldn't remove all of the $name skill. Left:" >&2
        skill_leftovers "$name" | sed 's/^/    /' >&2
        return 1
    fi
}

# Print the new SKILLS_STATE, given whether the add succeeded and the kept and removed stale
# skills, one name per line. After a successful add, it lists the repo's skills and the kept ones.
# After a failed add, it lists the old names, less the removed ones, plus the repo skills whose
# copies match, since the others may not be installed. A repo skill whose copy matches gets its
# repo hash; any other skill keeps the hash recorded before, or -.
skills_state() {
    local add_ok="$1" kept="$2" removed="$3" i name hash names
    if "$add_ok"; then
        names="$(printf '%s\n%s' "$(repo_skill_names)" "$kept")"
    else
        names="$(recorded_skill_names | LC_ALL=C comm -23 - <(printf '%s' "$removed" | sed '/^$/d' | LC_ALL=C sort -u))"
        for i in ${SKILL_NAMES[@]+"${!SKILL_NAMES[@]}"}; do
            [ -n "${SKILL_PROBLEM[i]}" ] || names="$names"$'\n'"${SKILL_NAMES[i]}"
        done
    fi
    printf '%s\n' "$names" | sed '/^$/d' | LC_ALL=C sort -u | while IFS= read -r name; do
        hash=""
        for i in ${SKILL_NAMES[@]+"${!SKILL_NAMES[@]}"}; do
            if [ "${SKILL_NAMES[i]}" == "$name" ] && [ -z "${SKILL_PROBLEM[i]}" ]; then
                hash="${SKILL_HASHES[i]}"
            fi
        done
        [ -n "$hash" ] || hash="$(recorded_skill_hash "$name")"
        printf '%s  %s\n' "${hash:--}" "$name"
    done
}

# Offer to remove each skill SKILLS_STATE lists that the repo no longer has, and drop the ones
# already gone, then write the new record (skills_state). A skill kept now, or not fully removed,
# stays in the record, so the next run offers it again. Takes whether the add succeeded. Fails
# when a removal or the write does.
remove_stale_skills() {
    local add_ok="$1" kept="" removed="" name result=0 dir tmp
    while IFS= read -r name <&3; do
        # Removed by hand already, so there's nothing left to offer
        if ! skill_installed "$name"; then
            removed="$removed$name"$'\n'
            continue
        fi
        if ! confirm "  Remove the $name skill, which ai_tools/skills no longer has?"; then
            echo "  Kept the $name skill, which ai_tools/skills no longer has"
            kept="$kept$name"$'\n'
        elif remove_skill "$name"; then
            removed="$removed$name"$'\n'
        else
            kept="$kept$name"$'\n'
            result=1
        fi
    done 3< <(stale_skill_names)
    # Written to a temp file and moved into place, so a failed write leaves the old record whole.
    # An unchanged record stays as it is.
    dir="$(dirname "$SKILLS_STATE")"
    if ! { mkdir -p "$dir" && tmp="$(mktemp "$dir/installed-skills.XXXXXX")"; }; then
        echo "  Couldn't record the installed skills in $SKILLS_STATE." >&2
        return 1
    fi
    if ! { skills_state "$add_ok" "$kept" "$removed" > "$tmp" &&
        if cmp -s "$tmp" "$SKILLS_STATE"; then
            rm -f "$tmp"
        else
            mv "$tmp" "$SKILLS_STATE"
        fi; }; then
        rm -f "$tmp"
        echo "  Couldn't record the installed skills in $SKILLS_STATE." >&2
        return 1
    fi
    return "$result"
}

status() {
    if ! node_new_enough; then
        status_item missing "Node.js $SKILLS_CLI_NODE_MAJOR or newer, for the skills CLI; install it with bash setup.sh runtimes"
    elif ! command -v npx &>/dev/null; then
        status_item missing "npx, which runs the skills CLI; install Node.js with bash setup.sh runtimes"
    else
        status_item ok "Node.js $SKILLS_CLI_NODE_MAJOR or newer and npx, for the skills CLI"
    fi
    local i name problems
    load_repo_skills 2>/dev/null ||
        status_item missing "Skill names in ai_tools/skills: one isn't lowercase letters, digits, and dashes, or two skills share one; run the step to see which"
    claude_skills_on || status_item skipped "Skills for Claude Code: CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, but setup assumes ~/.claude"
    check_skills
    problems="$(problem_skills)"
    for i in $problems; do
        status_item missing "${SKILL_NAMES[i]} skill, ${SKILL_PROBLEM[i]}"
    done
    [ -n "$problems" ] || status_item ok "Every skill in ai_tools/skills, installed and up to date"
    while IFS= read -r name; do
        if [ -n "$name" ] && skill_installed "$name"; then
            status_item missing "$name skill, which ai_tools/skills no longer has, still installed; the step offers to remove it"
        fi
    done <<< "$(stale_skill_names)"
    status_result
}

apply() {
    install_skills
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
