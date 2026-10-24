# The manual-steps steps' code. Each lists its README's manual steps in a manual_steps function,
# in steps.sh beside it: every step's markdown and, for one a script can check, the check and the
# text status reports. The step prints the steps that aren't done and reports the checks in
# --status; scripts/manual-steps-doc.sh writes the README's sections from the same list, and
# just check fails while they differ. Source after lib/common.sh; don't run it.
# shellcheck shell=bash

# shellcheck source=../scripts/lib/markdown.sh
source "$DOTFILES_DIR/scripts/lib/markdown.sh"

MANUAL_UNSURE_TEXT="the check couldn't tell"

# Starts the list; manual_steps calls it first
manual_reset() {
    MS_OS=()
    MS_ID=()
    MS_PARENT=()
    MS_GROUP=()
    MS_BULLET=()
    MS_BODY=()
    MS_CHECK=()
    MS_TEXT=()
    MS_KIND=()
    MS_KIDS=()
    MG_TEXT=()
    # shellcheck disable=SC2034 # manual_step reads them as ${!group}
    MANUAL_GROUP_macos=-1
    # shellcheck disable=SC2034
    MANUAL_GROUP_ubuntu=-1
}

manual_reset

_manual_os_ok() {
    case "$1" in
        macos | ubuntu) return 0 ;;
    esac
    echo "manual-steps: the OS is $1, not macos or ubuntu" >&2
    return 2
}

# manual_group <os> <line>: a line, such as **Apps**, over the OS's top-level steps declared after
# it. It shows while one of them does.
manual_group() {
    _manual_os_ok "$1" || return
    MG_TEXT+=("$2")
    printf -v "MANUAL_GROUP_$1" '%s' "$((${#MG_TEXT[@]} - 1))"
}

# manual_step <os> <id> [--parent <id>] [--bullet] [--optional | --elsewhere]
#   [--check <check> <status text>] < markdown
# The markdown's first line follows the list marker, and the rest are indented to its text, so a
# list in it nests. Steps are numbered, top-level ones counting on across the OS's groups, unless
# --bullet. --parent nests it under a step declared earlier, after that step's own markdown.
# The check, a function or a command and its arguments in one string, as item's, succeeds when the
# step is done, returns 1 when it isn't, and 2 when it can't tell, and may set MANUAL_DETAIL, which
# status shows after the text: why it can't tell, or what's left. Checks run in the step's shell, so
# one can leave what it found for apply. --optional: a step you may skip, which status reports as
# info when it isn't done. --elsewhere: another step's --status reports it, so this one leaves it out.
# A step without a check is done once it has steps under it and all are.
manual_step() {
    local os="$1" id="$2" parent=-1 bullet=false kind=required check="" text="" i body group
    shift 2
    _manual_os_ok "$os" || return
    while [ $# -gt 0 ]; do
        case "$1" in
            --parent)
                _manual_index "$os" "$2" || {
                    echo "manual_step $os $id: --parent $2 isn't a step declared before it" >&2
                    return 2
                }
                parent="$MANUAL_I"
                shift
                ;;
            --bullet) bullet=true ;;
            --optional | --elsewhere) kind="${1#--}" ;;
            --check)
                [ $# -ge 3 ] || { echo "manual_step $os $id: --check needs a check and a status text" >&2; return 2; }
                check="$2"
                text="$3"
                shift 2
                ;;
            *)
                echo "manual_step $os $id: unknown argument $1" >&2
                return 2
                ;;
        esac
        shift
    done
    if [[ ! "$id" =~ ^[a-z0-9-]+$ ]] || _manual_index "$os" "$id"; then
        echo "manual_step $os $id: an id is lowercase words joined by -, and unique on its OS" >&2
        return 2
    fi
    if [ -z "$check" ] && [ "$kind" != required ]; then
        echo "manual_step $os $id: --$kind needs --check" >&2
        return 2
    fi
    body="$(cat)"
    [ -n "$body" ] || { echo "manual_step $os $id: no markdown on stdin" >&2; return 2; }
    i=${#MS_ID[@]}
    MS_OS[i]="$os"
    MS_ID[i]="$id"
    MS_PARENT[i]="$parent"
    group="MANUAL_GROUP_$os"
    MS_GROUP[i]="${!group}"
    MS_BULLET[i]="$bullet"
    MS_BODY[i]="$body"
    MS_CHECK[i]="$check"
    MS_TEXT[i]="$text"
    MS_KIND[i]="$kind"
    MS_KIDS[i]=0
    [ "$parent" -lt 0 ] || MS_KIDS[parent]=$((MS_KIDS[parent] + 1))
}

# _manual_index <os> <id>: sets MANUAL_I to the step's index
_manual_index() {
    MANUAL_I=0
    while [ "$MANUAL_I" -lt ${#MS_ID[@]} ]; do
        [ "${MS_OS[MANUAL_I]}" != "$1" ] || [ "${MS_ID[MANUAL_I]}" != "$2" ] || return 0
        MANUAL_I=$((MANUAL_I + 1))
    done
    return 1
}

manual_os() {
    if is_macos; then echo macos; else echo ubuntu; fi
}

# The README's heading for the OS
manual_os_name() {
    case "$1" in
        macos) echo macOS ;;
        *) echo Ubuntu ;;
    esac
}

# manual_evaluate <os>: runs each of the OS's checks once, setting MS_RESULT and MS_DETAIL by step
# index, and MANUAL_DONE to the indexes of the steps done, space-separated. A memo scope spans them.
manual_evaluate() {
    local os="$1" i result MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    MS_RESULT=()
    MS_DETAIL=()
    MANUAL_DONE=" "
    for ((i = 0; i < ${#MS_ID[@]}; i++)); do
        [ "${MS_OS[i]}" == "$os" ] && [ -n "${MS_CHECK[i]}" ] || continue
        MANUAL_DETAIL=""
        result=0
        _item_run "${MS_CHECK[i]}" || result=$?
        case "$result" in 0 | 1) ;; *) result=2 ;; esac
        MS_RESULT[i]="$result"
        MS_DETAIL[i]="$MANUAL_DETAIL"
        [ "$result" -ne 0 ] || MANUAL_DONE+="$i "
    done
}

# manual_result <os> <id>: the step's check result from manual_evaluate, 2 when it didn't run
manual_result() {
    _manual_index "$1" "$2" && [ -n "${MS_RESULT[MANUAL_I]:-}" ] || return 2
    return "${MS_RESULT[MANUAL_I]}"
}

# Sets MS_ISDONE for each of the OS's steps, from MANUAL_DONE. Children come after their parent,
# so a reverse pass sees them first.
_manual_mark_done() {
    local i parent is_done kids_done=()
    MS_ISDONE=()
    for ((i = ${#MS_ID[@]} - 1; i >= 0; i--)); do
        [ "${MS_OS[i]}" == "$1" ] || continue
        is_done=false
        if [ -n "${MS_CHECK[i]}" ]; then
            [[ "${MANUAL_DONE:- }" != *" $i "* ]] || is_done=true
        elif [ "${MS_KIDS[i]}" -gt 0 ] && [ "${kids_done[i]:-0}" -eq "${MS_KIDS[i]}" ]; then
            is_done=true
        fi
        MS_ISDONE[i]="$is_done"
        parent="${MS_PARENT[i]}"
        if "$is_done" && [ "$parent" -ge 0 ]; then
            kids_done[parent]=$((${kids_done[parent]:-0} + 1))
        fi
    done
}

# manual_markdown <os>: the OS's steps as the README lists them, leaving out those MANUAL_DONE
# marks done, and a group with none left
manual_markdown() {
    local os="$1" i group=-1 num=0 printed=false
    _manual_mark_done "$os"
    for ((i = 0; i < ${#MS_ID[@]}; i++)); do
        if [ "${MS_OS[i]}" != "$os" ] || [ "${MS_PARENT[i]}" -ge 0 ] || "${MS_ISDONE[i]}"; then
            continue
        fi
        if [ "${MS_GROUP[i]}" != "$group" ]; then
            group="${MS_GROUP[i]}"
            if [ "$group" -ge 0 ]; then
                ! "$printed" || echo ""
                echo "${MG_TEXT[group]}"
                echo ""
            fi
        fi
        "${MS_BULLET[i]}" || num=$((num + 1))
        _manual_item "$i" "" "$num"
        printed=true
    done
}

# _manual_item <index> <indent> <number>: the step, then the steps under it not done
_manual_item() {
    local i="$1" indent="$2" marker="$3." pad line first=true j num=0
    ! "${MS_BULLET[i]}" || marker=-
    printf -v pad '%*s' $((${#indent} + ${#marker} + 1)) ''
    while IFS= read -r line; do
        if "$first"; then
            echo "$indent$marker $line"
            first=false
        elif [ -z "$line" ]; then
            echo ""
        else
            echo "$pad$line"
        fi
    done <<< "${MS_BODY[i]}"
    for ((j = i + 1; j < ${#MS_ID[@]}; j++)); do
        if [ "${MS_PARENT[j]}" != "$i" ] || "${MS_ISDONE[j]}"; then
            continue
        fi
        "${MS_BULLET[j]}" || num=$((num + 1))
        _manual_item "$j" "$pad" "$num"
    done
}

# manual_print [what]: this OS's steps not done, under a line saying how many it left out.
# MANUAL_DOC, which steps.sh sets, is the README the links in the steps point from.
manual_print() {
    local os what="${1:-manual steps}" text count left_out=""
    os="$(manual_os)"
    manual_evaluate "$os"
    count="$(wc -w <<< "$MANUAL_DONE" | tr -d ' ')"
    [ "$count" -eq 0 ] || left_out=", leaving out the $count done (--status lists them)"
    text="$(manual_markdown "$os")"
    echo ""
    # shellcheck disable=SC2153 # steps.sh sets MANUAL_DOC
    echo "Remaining $what on $(manual_os_name "$os") ($(shown_path "$MANUAL_DOC") → Manual steps)$left_out:"
    if [ -z "$text" ]; then
        echo "  None."
    else
        printf '%s\n' "$text" | print_doc_text "$MANUAL_DOC"
    fi
}

# status_manual <command that prints the steps>: each of this OS's checks, apart from --elsewhere
# ones
status_manual() {
    local os i text detail
    if status_for_alerts; then
        status_item skipped "Manual steps: skipped by --for-alerts, since they're to-dos rather than health"
        return 0
    fi
    os="$(manual_os)"
    manual_evaluate "$os"
    for ((i = 0; i < ${#MS_ID[@]}; i++)); do
        [ "${MS_OS[i]}" == "$os" ] && [ -n "${MS_CHECK[i]}" ] && [ "${MS_KIND[i]}" != elsewhere ] || continue
        text="${MS_TEXT[i]}"
        detail="${MS_DETAIL[i]}"
        case "${MS_RESULT[i]}:${MS_KIND[i]}" in
            0:*) status_item ok "$text${detail:+: $detail}" ;;
            1:optional) status_item info "$text: not done, which is optional${detail:+; $detail}" ;;
            1:*) status_item missing "$text${detail:+: $detail}" ;;
            *) status_item unverified "$text: ${detail:-$MANUAL_UNSURE_TEXT}" ;;
        esac
    done
    status_item info "Manual steps no script can check: $1 lists them with the rest left to do"
}

# A check of several parts calls manual_parts_start, then manual_part per part, and returns
# manual_parts_result: not done when any part isn't, else unsure when any part is, with the
# details of the parts that decide it.
manual_parts_start() {
    MANUAL_LEFT=()
    MANUAL_UNSURE=()
}

# manual_part <what's left when it fails> <check...>: a MANUAL_DETAIL the check sets goes after it
manual_part() {
    local what="$1" result=0
    shift
    MANUAL_DETAIL=""
    "$@" || result=$?
    case "$result" in
        0) ;;
        1) MANUAL_LEFT+=("$what${MANUAL_DETAIL:+: $MANUAL_DETAIL}") ;;
        *) MANUAL_UNSURE+=("${MANUAL_DETAIL:-$MANUAL_UNSURE_TEXT}") ;;
    esac
}

manual_parts_result() {
    MANUAL_DETAIL=""
    if [ ${#MANUAL_LEFT[@]} -gt 0 ]; then
        MANUAL_DETAIL="$(printf '%s\n' "${MANUAL_LEFT[@]}" | join_lines '; ')"
        return 1
    elif [ ${#MANUAL_UNSURE[@]} -gt 0 ]; then
        MANUAL_DETAIL="$(printf '%s\n' "${MANUAL_UNSURE[@]}" | awk '!seen[$0]++' | join_lines '; ')"
        return 2
    fi
}

# manual_unknown <why>: a check's return when it can't tell
manual_unknown() {
    MANUAL_DETAIL="$1"
    return 2
}

# step_check <step script> <command...>: runs a check another step defines, in a subshell, so that
# step's status, apply, and constants don't replace the caller's
step_check() {
    local script="$DOTFILES_DIR/$1"
    shift
    (
        # shellcheck disable=SC1090 # a step script
        source "$script" && "$@"
    )
}

# tailscale_status_json [tailscale command]: tailscale status --json, cached through a memo scope
# once called outside a $( )
tailscale_status_json() {
    memo TAILSCALE_STATUS_JSON "${1:-tailscale}" status --json 2>/dev/null
}

# git_signing_done: commits sign with an SSH key, and GitHub lists it as a signing key
git_signing_done() {
    local key keys
    # shellcheck source=../git/lib/config.sh
    source "$DOTFILES_DIR/git/lib/config.sh"
    key="$(git_user_config --get user.signingkey 2>/dev/null)" || key=""
    if [ "$(git_user_config --get gpg.format 2>/dev/null)" != ssh ] ||
        [ "$(git_user_config --get commit.gpgsign 2>/dev/null)" != true ] || [ -z "$key" ]; then
        MANUAL_DETAIL="git doesn't sign commits with an SSH key yet"
        return 1
    fi
    # shellcheck disable=SC2088 # a literal ~/ in git's config
    case "$key" in "~/"*) key="$HOME/${key#"~/"}" ;; esac
    if [ ! -r "$key" ]; then
        MANUAL_DETAIL="user.signingkey names $key, which can't be read"
        return 1
    fi
    command -v gh &>/dev/null || manual_unknown "gh isn't installed, so GitHub's signing keys can't be listed" || return
    keys="$(run_bounded 20 gh api user/ssh_signing_keys --jq '.[].key' 2>/dev/null)" ||
        manual_unknown "couldn't list GitHub's signing keys; gh auth refresh -h github.com -s admin:ssh_signing_key lets gh read them" ||
        return
    if ! grep -qxF "$(awk '{ print $1, $2 }' "$key")" <<< "$keys"; then
        MANUAL_DETAIL="GitHub doesn't list $(shown_path "$key") as a signing key; just git-signing prints the gh commands that add it"
        return 1
    fi
}

github_logged_in() {
    gh auth token --hostname github.com &>/dev/null
}

# claude_in_chrome_done <Chrome's profile dir>: the extension in a Chrome profile, and Claude Code's
# native messaging host, which claude --chrome installs
claude_in_chrome_done() {
    local missing=()
    compgen -G "$1/*/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn" > /dev/null ||
        missing+=("the extension isn't installed in Chrome")
    [ -e "$1/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json" ] ||
        missing+=("claude --chrome hasn't run")
    [ ${#missing[@]} -gt 0 ] || return 0
    MANUAL_DETAIL="$(printf '%s\n' "${missing[@]}" | join_lines ', and ')"
    return 1
}

NOTIFICATION_SETTINGS="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"

# Print "<bundle id> <flags>" per app. Only keys of an app's own dict count, not nested ones.
notification_flags() {
    local xml
    xml="$(plutil -extract apps xml1 -o - "$NOTIFICATION_SETTINGS" 2>/dev/null)" || return 1
    printf '%s\n' "$xml" | awk '
        /<dict>/ { if (++depth == 1) { id = ""; flags = "" } next }
        /<\/dict>/ { if (depth-- == 1 && id != "") print id, flags; next }
        depth != 1 { next }
        /<key>bundle-id<\/key>/ { want = "string"; next }
        /<key>flags<\/key>/ { want = "integer"; next }
        want != "" {
            if (match($0, "<" want ">[^<]*</" want ">")) {
                value = substr($0, RSTART + length(want) + 2, RLENGTH - 2 * length(want) - 5)
                if (want == "string") id = value; else flags = value
            }
            want = ""
        }'
}

# Print each given app not set to Allow + Persistent. Fails without Full Disk Access.
# Bits per https://github.com/drewdiver/ncprefs.py: 1<<25 allow, 1<<3 banners, 1<<4 alerts.
notifications_pending() {
    local apps id flags wanted=" $* " persistent=" "
    apps="$(notification_flags)" || return 1
    while read -r id flags; do
        [[ "$wanted" == *" $id "* ]] && [[ "$flags" =~ ^[0-9]+$ ]] || continue
        if (( (flags >> 25 & 1) && (flags >> 4 & 1) && !(flags >> 3 & 1) )); then
            persistent+="$id "
        fi
    done <<< "$apps"
    for id; do
        [[ "$persistent" == *" $id "* ]] || echo "$id"
    done
}

# shellcheck disable=SC2034 # the manual-steps checks read it
NOTIFICATIONS_UNREADABLE="macOS lets only a terminal with Full Disk Access read the notification settings"
