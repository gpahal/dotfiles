# shellcheck shell=bash
# What the macOS open-in beside it and the Ubuntu one (stream-deck/linux/bin/open-in) share. Each
# sources it from its own folder, so every installed copy of either has it alongside. They set
# NEW_TAB_LOCK, CALLER_LOG, FRONT_KIND (app or window, whichever their front thing is),
# CONTEXT_PATH, and FAILURE.

# The callers timestamp each line
log() {
    printf '%s\n' "$*" >&2
}

usage() {
    echo "Usage: open-in editor|terminal|files|agenda|chrome|chrome-tab|gmail|notion|t3-code|claude|activity-monitor|upgrade" >&2
}

# Relies on zed/settings.json's window_title_format "${projectName}${separator}${filePath}"
zed_title_path() {
    case "$1" in
        *" — /"*) CONTEXT_PATH="/${1#*" — /"}" ;;
        *" — ~/"*) CONTEXT_PATH="$HOME/${1#*" — ~/"}" ;;
    esac
}

# t3_folder <state database> <thread ID> <window title>: sets CONTEXT_PATH to the folder of the T3
# Code thread the window shows, its worktree, else its project's, from T3 Code's state database. The
# thread ID picks it; with none, the thread whose title the window's names, else the one used last,
# leaving out archived and deleted ones. These are T3 Code internals. The title is matched in jq,
# not the query, so no window's text reaches SQL.
t3_folder() {
    local rows
    if ! command -v sqlite3 > /dev/null; then
        log "T3 Code's thread folder needs sqlite3, from the Brewfile. Run: bash setup.sh homebrew"
        return 0
    fi
    if ! rows="$(sqlite3 -readonly -json "$1" "
        SELECT t.thread_id AS id, t.title, t.updated_at AS updated,
            t.archived_at IS NULL AND t.deleted_at IS NULL AS open,
            coalesce(json_extract(t.payload_json, '\$.worktreePath'), p.workspace_root) AS folder
        FROM orchestration_v2_projection_threads t
        LEFT JOIN projection_projects p ON p.project_id = t.project_id" 2>&1)"; then
        log "ERROR couldn't read T3 Code's threads from $1: $rows"
        return 0
    fi
    CONTEXT_PATH="$(jq -r --arg id "$2" --arg title "$3" '
        map(select(.open == 1)) as $open |
        (if $id != "" then first(.[] | select(.id == $id))
         else first($open[] | select((.title // "") as $t | $t != "" and $title != "" and ($title | contains($t)))) //
             ($open | max_by(.updated)) end) |
        .folder // empty' <<< "${rows:-[]}" 2> /dev/null)" || CONTEXT_PATH=""
    log "T3 Code's thread folder: ${CONTEXT_PATH:-none found}"
}

# claude_folder <sessions dir> <session UUID> <window title> <any>: sets CONTEXT_PATH to the folder
# of the Claude app's Code session the window shows. Each session is a local_<id>.json in
# <dir>/<account>/<org>/, with its sessionId (local_<UUID>), the Claude Code session's cliSessionId,
# title, and folder (cwd, else originCwd). A UUID from the page's address picks it; else the
# window's title naming the session's; else, with <any> "yes", the session used last. These are
# Claude app internals, so a session not found leaves no folder.
claude_folder() {
    local dir="$1" files=()
    shopt -s nullglob
    files=("$dir"/*/*/local_*.json)
    shopt -u nullglob
    [ "${#files[@]}" -gt 0 ] || return 0
    CONTEXT_PATH="$(jq -rs --arg id "$2" --arg title "$3" --arg any "$4" '
        map(select(type == "object")) as $all | ($all | map(select(.isArchived != true))) as $open |
        (first($all[] | select($id != "" and (.sessionId == "local_\($id)" or .cliSessionId == $id))) //
         first($open[] | select((.title // "") as $t | $t != "" and $title != "" and ($title | contains($t)))) //
         (if $any == "yes" then $open | max_by(.lastActivityAt // .createdAt // 0) else null end)) |
        .cwd // .originCwd // empty' "${files[@]}" 2> /dev/null)" || CONTEXT_PATH=""
    log "Claude's session folder: ${CONTEXT_PATH:-none found}"
}

# Keeps CONTEXT_PATH only when it exists here: remote paths, such as a Zed project over SSH, don't
check_context_path() {
    [ "$CONTEXT_PATH" == / ] || CONTEXT_PATH="${CONTEXT_PATH%/}"
    [ -n "$CONTEXT_PATH" ] && [ -e "$CONTEXT_PATH" ] || CONTEXT_PATH=""
}

# open_path_result <target> <status>: notes a failure to open CONTEXT_PATH, unless one is noted
open_path_result() {
    [ "$2" -ne 0 ] && [ -z "$FAILURE" ] || return 0
    log "ERROR couldn't open ${CONTEXT_PATH:-a new window} for $1"
    FAILURE="Couldn't open ${CONTEXT_PATH:-a new window}. See $CALLER_LOG"
}

# One New Tab at a time, from the Stream Deck and the hotkeys alike: two at once would each open a
# tab, then both paste into whichever is in front. mkdir is atomic. A lock whose process is gone,
# or that got no process ID within a minute, is taken over.
take_new_tab_lock() {
    local pid=""
    if ! mkdir "$NEW_TAB_LOCK" 2> /dev/null; then
        read -r pid < "$NEW_TAB_LOCK/pid" 2> /dev/null
        if [ -n "$pid" ]; then
            ! kill -0 "$pid" 2> /dev/null || return 1
        elif [ -z "$(find "$NEW_TAB_LOCK" -maxdepth 0 -mmin +1 2> /dev/null)" ]; then
            return 1
        fi
        rm -rf "$NEW_TAB_LOCK"
        mkdir "$NEW_TAB_LOCK" 2> /dev/null || return 1
    fi
    echo "$$" > "$NEW_TAB_LOCK/pid"
    trap 'rm -rf "$NEW_TAB_LOCK"' EXIT
}

# new_tab_result <target> <new tab's status> <moved, if another app came to the front before the
# paste> <paste, if it pasted>
new_tab_result() {
    if [ "$2" -ne 0 ]; then
        [ -n "$FAILURE" ] || FAILURE="Couldn't open a new Chrome tab. See $CALLER_LOG"
    elif [ "$3" == moved ]; then
        log "$1: opened a new tab, but another $FRONT_KIND came to the front before the paste"
    elif [ "$4" == paste ]; then
        log "$1: opened a new tab with the clipboard pasted"
    else
        log "$1: opened a new tab"
    fi
}
