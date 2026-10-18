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

# The skills this repo installed, one name per line. Only these are ever offered for removal, so
# skills added from elsewhere are left alone. It sits beside the skills CLI's own lock file.
SKILLS_STATE="$HOME/.agents/.dotfiles-installed-skills"
# The skill_sha256 of each skill's copy in ~/.agents/skills when it last matched the repo, as
# "<hash>  <name>" lines, so a copy edited by hand since can be backed up before it's replaced
SKILLS_HASHES="$SKILLS_STATE.sha256"
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

# Print a skill's name: the `name:` field in its SKILL.md frontmatter, without YAML quotes
skill_name() {
    awk '/^---/ { n++; next }
        n == 1 && /^name:/ {
            sub(/^name:[ \t]*/, ""); sub(/[ \t]+$/, "")
            if ($0 ~ /^".*"$/ || $0 ~ /^\047.*\047$/) $0 = substr($0, 2, length($0) - 2)
            print; exit
        }' "$1"
}

# Print the name of every skill in the repo, sorted
repo_skill_names() {
    local file
    find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md | while IFS= read -r file; do
        skill_name "$file"
    done | sort -u
}

# Print the dir_sha256 of a skill's directory, leaving out what the skills CLI doesn't copy
skill_sha256() {
    dir_sha256 "$1" "${SKILLS_CLI_EXCLUDES[@]}"
}

# Print why a repo skill, given its SKILL.md, needs adding again: "not installed" or "out of date".
# Prints nothing when it's installed for both agents and matches the repo, down to which files
# are executable. Claude Code's copy must be the skills CLI's link to the Codex copy, so a stale
# directory or a link to another copy counts as out of date.
skill_problem() {
    local name dir installed resolved want
    name="$(skill_name "$1")"
    dir="$(dirname "$1")"
    installed="$HOME/.agents/skills/$name"
    # -d first: GNU and uutils realpath, unlike macOS's, succeed when only the last part is missing
    if [ -z "$name" ] || [ ! -d "$installed" ] || ! resolved="$(realpath "$installed" 2>/dev/null)"; then
        echo "not installed"
    elif ! { { ! claude_skills_on || [ "$(realpath "$HOME/.claude/skills/$name" 2>/dev/null)" = "$resolved" ]; } &&
        want="$(skill_sha256 "$dir")" && [ "$(skill_sha256 "$installed" 2>/dev/null)" = "$want" ]; }; then
        echo "out of date"
    fi
}

# Succeeds when no skill in the repo needs adding again. Adding them again would only bump the
# timestamps in the skills CLI's lock file.
skills_up_to_date() {
    local file
    while IFS= read -r file; do
        [ -z "$(skill_problem "$file")" ] || return 1
    done < <(find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md)
}

# Succeeds when node is at least SKILLS_CLI_NODE_MAJOR
node_new_enough() {
    local major
    major="$(node --version 2>/dev/null)" || return 1
    major="${major#v}"
    major="${major%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge "$SKILLS_CLI_NODE_MAJOR" ]
}

# Print the hash SKILLS_HASHES records for a skill, or nothing
recorded_skill_hash() {
    [ -f "$SKILLS_HASHES" ] || return 0
    awk -v name="$1" 'substr($0, 67) == name { print substr($0, 1, 64); exit }' "$SKILLS_HASHES"
}

# Record the hash of each repo skill whose installed copy matches the repo, keeping the old line
# of any other. Only a copy that matches is recorded, so this is safe after a failed add too.
# Given "missing", it hashes only the skills with no record, since the others' copies haven't
# changed.
record_skill_hashes() {
    local file name hash lines="" changed=false
    while IFS= read -r file; do
        name="$(skill_name "$file")"
        [ -n "$name" ] || continue
        hash="$(recorded_skill_hash "$name")"
        if { [ "${1:-}" != missing ] || [ -z "$hash" ]; } && [ -z "$(skill_problem "$file")" ]; then
            hash="$(skill_sha256 "$HOME/.agents/skills/$name")" || continue
            changed=true
        fi
        [ -z "$hash" ] || lines="$lines$hash  $name"$'\n'
    done < <(find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md)
    "$changed" || return 0
    if ! { mkdir -p "$(dirname "$SKILLS_HASHES")" &&
        printf '%s' "$lines" | sort -k2 >"$SKILLS_HASHES.tmp" &&
        mv "$SKILLS_HASHES.tmp" "$SKILLS_HASHES"; }; then
        echo "  Couldn't record the installed skills' hashes in $SKILLS_HASHES." >&2
    fi
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

# Before the add replaces a skill's installed copy, back up what was edited by hand: the copy in
# ~/.agents/skills when it matches neither the repo nor the hash recorded when setup installed it,
# and a real directory at ~/.claude/skills/<name>, where the CLI puts a link, unless it matches
# the repo. --backup or --no-backup (DOTFILES_BACKUP) decides; otherwise ask with a terminal, and
# back up without one, as copy_file does. Fails when a backup does, so the add skips the skill.
backup_edited_skill() {
    local name="$1" src="$2" agents="$HOME/.agents/skills/$1" claude="$HOME/.claude/skills/$1"
    local repo_hash hash dir label edited=()
    repo_hash="$(skill_sha256 "$src")" || return 1
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
    # The skills CLI (https://skills.sh) copies the skills into ~/.agents/skills (Codex) and
    # symlinks them into ~/.claude/skills (Claude Code). Re-run after changing a skill.
    # DO_NOT_TRACK turns off its telemetry.
    local add_failed=false result=0 file name add held="" agents=()
    while IFS= read -r name; do agents+=("$name"); done < <(skill_agents)
    claude_skills_on || echo "  CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, but setup assumes ~/.claude, so the skills are for Codex only."
    if skills_up_to_date; then
        echo "  Every skill is already installed and up to date."
        record_skill_hashes missing
    else
        add=()
        # Read on fd 3, so backup_edited_skill's confirm reads the terminal, not find's output
        while IFS= read -r file <&3; do
            name="$(skill_name "$file")"
            [ -n "$name" ] || continue
            if [ -n "$(skill_problem "$file")" ] && ! backup_edited_skill "$name" "$(dirname "$file")"; then
                held="$held $name"
            else
                add+=("$name")
            fi
        done 3< <(find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md | sort)
        # A skill whose backup failed is left out, so its edits survive
        if [ -n "$held" ]; then
            add=(--skill ${add[@]+"${add[@]}"})
        else
            add=(--skill '*')
        fi
        if [ "${#add[@]}" -gt 1 ]; then
            DO_NOT_TRACK=1 npx -y "$SKILLS_CLI" add "$DOTFILES_DIR/ai_tools/skills" \
                --global --agent "${agents[@]}" "${add[@]}" --yes || add_failed=true
            # The CLI can exit zero after a per-skill copy failure. Verify every requested copy.
            while IFS= read -r file; do
                name="$(skill_name "$file")"
                [[ " $held " != *" $name "* ]] || continue
                if [ -n "$(skill_problem "$file")" ]; then
                    echo "  $name wasn't installed correctly: $(skill_problem "$file")" >&2
                    add_failed=true
                fi
            done < <(find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md)
        fi
        if [ -n "$held" ]; then
            echo "  Didn't add these skills, since their edited copies couldn't be backed up:$held" >&2
            result=1
        fi
        record_skill_hashes
    fi
    # Stale skills don't depend on the add, so remove them even when it failed
    if "$add_failed"; then
        remove_stale_skills false || true
        echo "  The skills CLI failed to add the skills." >&2
        return 1
    fi
    remove_stale_skills true || result=1
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

# Print the skills the state file lists that the repo no longer has, given the repo's names
stale_skill_names() {
    [ -s "$SKILLS_STATE" ] || return 0
    printf '%s\n' "$1" | comm -13 - <(sort -u "$SKILLS_STATE")
}

# Remove a stale skill for every agent. Fails, printing what's left, when the skills CLI fails or
# anything of the skill is left.
remove_skill() {
    local name="$1" agent agents=()
    while IFS= read -r agent; do agents+=("$agent"); done < <(skill_agents)
    if ! DO_NOT_TRACK=1 npx -y "$SKILLS_CLI" remove --global --agent "${agents[@]}" --yes "$name"; then
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

# Write the new state file to $SKILLS_STATE.tmp, given remove_stale_skills's add_ok, the repo's
# skill names, and the kept and removed skills
write_skills_state() {
    if "$1"; then
        printf '%s\n%s' "$2" "$3" | sed '/^$/d' | sort -u >"$SKILLS_STATE.tmp"
    elif [ -f "$SKILLS_STATE" ]; then
        printf '%s' "$4" | sed '/^$/d' | sort -u | comm -23 <(sort -u "$SKILLS_STATE") - >"$SKILLS_STATE.tmp"
    else
        : >"$SKILLS_STATE.tmp"
    fi
}

# Offer to remove each skill the state file lists that the repo no longer has, and drop the ones
# already gone. A skill kept now, or not fully removed, stays in the state file, so the next run
# offers it again. Takes whether the add succeeded. After a failed add the record keeps its old
# names, less the ones removed now, since the repo's skills may not be installed. Fails when a
# removal does.
remove_stale_skills() {
    local add_ok="$1" current kept="" removed="" name result=0
    current="$(repo_skill_names)"
    for name in $(stale_skill_names "$current"); do
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
    done
    # Called where set -e is off, so a failed write must stop the mv over the old record. An
    # unchanged record stays as it is.
    if ! { mkdir -p "$(dirname "$SKILLS_STATE")" && write_skills_state "$add_ok" "$current" "$kept" "$removed" &&
        if cmp -s "$SKILLS_STATE.tmp" "$SKILLS_STATE"; then
            rm -f "$SKILLS_STATE.tmp"
        else
            mv "$SKILLS_STATE.tmp" "$SKILLS_STATE"
        fi; }; then
        rm -f "$SKILLS_STATE.tmp" 2>/dev/null
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
    local file name problem all_ok=true
    claude_skills_on || status_item skipped "Skills for Claude Code: CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, but setup assumes ~/.claude"
    while IFS= read -r file; do
        problem="$(skill_problem "$file")"
        if [ -n "$problem" ]; then
            name="$(skill_name "$file")"
            status_item missing "${name:-$(basename "$(dirname "$file")")} skill, $problem"
            all_ok=false
        fi
    done < <(find "$DOTFILES_DIR/ai_tools/skills" -name SKILL.md | sort)
    ! "$all_ok" || status_item ok "Every skill in ai_tools/skills, installed and up to date"
    for name in $(stale_skill_names "$(repo_skill_names)"); do
        if skill_installed "$name"; then
            status_item missing "$name skill, which ai_tools/skills no longer has, still installed; the step offers to remove it"
        fi
    done
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    install_skills
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
