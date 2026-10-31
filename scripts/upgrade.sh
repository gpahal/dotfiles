#!/bin/bash
set -u

# Update everything installed, or with ai-tools, only the AI tools.
# No set -e: a failed stage mustn't stop the ones after it.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"

# Given casks, brew outdated exits 1 when it lists one, so only exit >1 or 1 with no output fails.
_brew_casks_outdated() {
    local output rc=0
    output="$(brew outdated --cask --greedy --quiet "$@" 2>/dev/null)" || rc=$?
    ! interrupted_status "$rc" || return "$rc"
    if [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && [ -n "$output" ]; }; then
        [ -z "$output" ] || printf '%s\n' "$output"
        return 0
    fi
    return 1
}

_installed_casks() {
    brew list --cask -1 2>/dev/null
}

_cask_listed() {
    awk -F / -v cask="$1" '$NF == cask { found = 1 } END { exit !found }'
}

# Stops upgrade on an interrupt, which brew reports by exiting 130 rather than dying of SIGINT
_exit_if_interrupted() {
    interrupted_status "$1" || return 0
    echo "Interrupted; stopping." >&2
    exit "$1"
}

# _run <cmd> [arg...]: returns the command's status, exiting on an interrupt
_run() {
    local rc=0
    "$@" || rc=$?
    _exit_if_interrupted "$rc"
    return "$rc"
}

# _capture <var> <cmd> [arg...]: sets <var> to the command's output, as _run does its status
_capture() {
    local _capture_out _capture_rc=0
    _capture_out="$("${@:2}")" || _capture_rc=$?
    _exit_if_interrupted "$_capture_rc"
    printf -v "$1" '%s' "$_capture_out"
    return "$_capture_rc"
}

# Casks whose running app upgrade never quits: Ghostty is likely the terminal it runs in
KEEP_RUNNING_CASKS=(ghostty)
# How long a running app gets to quit before it's left alone, as when it asks to save
APP_QUIT_SECONDS=20

# Upgrade outdated casks. Replacing a running app's files would break it, so a running app is
# skipped, or with --replace-running, on macOS, quit, upgraded, and opened again in the background,
# unless it's in KEEP_RUNNING_CASKS. The ones left running are named in one line at the end.
# Usage: _upgrade_self_updating_casks <command to re-run> [--replace-running] <cask>[:<process>]...
_upgrade_self_updating_casks() {
    local rerun="$1" entry cask process path app running installed outdated one pattern rc replace=false
    local exit_status=0 listed=() names=() skipped=()
    shift
    [ "${1:-}" != --replace-running ] || { replace=true; shift; }
    if ! _capture installed _installed_casks; then
        echo "Couldn't list the installed casks: brew list --cask failed." >&2
        return 1
    fi
    for entry in "$@"; do
        if _cask_listed "${entry%%:*}" <<< "$installed"; then
            listed+=("$entry")
            names+=("${entry%%:*}")
        fi
    done
    [ ${#listed[@]} -gt 0 ] || return 0
    if ! _capture outdated _brew_casks_outdated "${names[@]}"; then
        # One unknown cask fails the whole query, so ask each alone
        outdated=""
        for cask in "${names[@]}"; do
            if _capture one _brew_casks_outdated "$cask"; then
                outdated+="$one"$'\n'
            else
                echo "Couldn't check whether $cask is up to date: brew outdated failed." >&2
                exit_status=1
            fi
        done
    fi
    for entry in "${listed[@]}"; do
        cask="${entry%%:*}"
        process=""
        [ "$cask" == "$entry" ] || process="${entry#*:}"
        _cask_listed "$cask" <<< "$outdated" || continue
        running=false
        if [ -n "$process" ]; then
            app="$cask"
            ! pgrep -x "$process" &>/dev/null || running=true
        else
            # Without jq, cask_app_path prints nothing, which would pass for a cask with no app
            if ! command -v jq &>/dev/null || ! _capture path cask_app_path "$cask"; then
                echo "Couldn't read $cask's metadata; leaving it alone." >&2
                exit_status=1
                continue
            fi
            app="${path##*/}"
            app="${app%.app}"
            if [ -n "$app" ] && _cask_app_renamed "$cask" "$path"; then
                _run _readopt_renamed_cask "$cask" "$path" || exit_status=1
                continue
            fi
            # An app's name can gain or lose a " (...)" suffix between releases, so match up to " ("
            app="${app%% (*}"
            pattern="^$(regex_escape "${path%/*}/$app")[^/]*\.app/Contents/MacOS/"
            # -a: macOS pgrep otherwise skips its own ancestors, such as the app this shell runs in
            if [ -n "$app" ] && pgrep -af "$pattern" &>/dev/null; then
                running=true
            fi
        fi
        if ! "$running"; then
            _run brew upgrade --cask --greedy "$cask" || exit_status=1
        elif "$replace" && [ -z "$process" ] && is_macos && [[ " ${KEEP_RUNNING_CASKS[*]} " != *" $cask "* ]]; then
            rc=0
            _replace_running_app "$cask" "$path" "$app" "$pattern" || rc=$?
            case "$rc" in
                0) ;;
                2) skipped+=("$app") ;;
                *) exit_status=1 ;;
            esac
        else
            skipped+=("$app")
        fi
    done
    if [ ${#skipped[@]} -gt 0 ]; then
        one="$(printf '%s, ' "${skipped[@]}")"
        echo "Running, so not updated: ${one%, }. Quit them and run $rerun again."
    fi
    return "$exit_status"
}

# _replace_running_app <cask> <app path> <app name> <pgrep pattern>: quits the app, upgrades its
# cask, and opens it again, by bundle ID, in case the upgrade renamed it. Returns 2 when the app
# doesn't quit, leaving it running and the cask as it was.
_replace_running_app() {
    local cask="$1" id waited=0 status=0
    id="$(defaults read "$2/Contents/Info" CFBundleIdentifier 2>/dev/null)" || return 2
    [ -n "$id" ] || return 2
    echo "Quitting $3 to update it; it opens again after."
    osascript -e "with timeout of $APP_QUIT_SECONDS seconds" -e "quit app id \"$id\"" -e "end timeout" \
        &>/dev/null || return 2
    while pgrep -af "$4" &>/dev/null; do
        [ "$waited" -lt "$APP_QUIT_SECONDS" ] || return 2
        sleep 1
        waited=$((waited + 1))
    done
    _run brew upgrade --cask --greedy "$cask" || status=$?
    open -g -b "$id" || echo "Couldn't open $3 again; open it yourself." >&2
    return "$status"
}

# Casks upgrade-ai-tools updates, which upgrade's general pass leaves to it
AI_CASKS=(claude chatgpt t3-code codex)

# Every installed cask but the AI ones, which can include the app running this session (T3 Code).
# brew upgrade skips the ones marked auto_updates, nearly all of them; this quits a running one,
# upgrades it, and opens it again.
_upgrade_installed_casks() {
    local installed cask entries=()
    if ! _capture installed _installed_casks; then
        echo "Couldn't list the installed casks: brew list --cask failed." >&2
        return 1
    fi
    while IFS= read -r cask; do
        [ -n "$cask" ] || continue
        [[ " ${AI_CASKS[*]} " != *" $cask "* ]] || continue
        # Zed's Linux process isn't named after its app
        if [ "$cask" == zed ] && ! is_macos; then
            cask=zed:zed-editor
        fi
        entries+=("$cask")
    done <<< "$installed"
    [ ${#entries[@]} -gt 0 ] || return 0
    _upgrade_self_updating_casks upgrade --replace-running "${entries[@]}"
}

# The app renamed itself as it updated (T3 Code can). Only for casks whose uninstall just removes the app,
# since _readopt_renamed_cask runs that uninstall.
_cask_app_renamed() {
    local recorded
    jq -e '.uninstall_artifacts | all(.[]; type == "object" and (keys - ["app", "zap", "target"] | length == 0))' \
        "$(cask_receipt "$1")" &>/dev/null || return 1
    recorded="$(recorded_cask_app "$1" "$2")" || return 1
    [ "$recorded" != "$2" ] && [ ! -e "$recorded" ] && [ -d "$2" ]
}

# Adopting in place leaves a running app alone.
_readopt_renamed_cask() {
    local status=0
    echo "${2##*/} renamed itself as it updated, so Homebrew's record of $1 is stale; re-recording it."
    brew uninstall --cask --force "$1" || return
    brew install --cask --adopt "$1" || status=$?
    if [ "$status" -ne 0 ] && ! interrupted_status "$status"; then
        echo "Couldn't re-record $1. Run: brew install --cask --adopt $1" >&2
    fi
    return "$status"
}

# Runs in a new bash so the step's set -e holds; a subshell tested with || would ignore it
_step_fn() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    "$BASH" -c 'source "$1/$2/install.sh" && "$3"' bash "$DOTFILES_DIR" "$1" "$2"
}

_stage_failed() {
    _exit_if_interrupted "$2"
    failed+=("$1")
}

_claude_marketplace_versions() {
    local name dir
    claude plugin marketplace list --json 2>/dev/null |
        jq -r '.[]? | [.name, .installLocation // ""] | @tsv' 2>/dev/null |
        while IFS=$'\t' read -r name dir; do
            # -C "" would run git in the current directory
            if [ -n "$dir" ] && [ -e "$dir/.git" ]; then
                printf '%s\t%s\n' "$name" "$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null || echo -)"
            else
                printf '%s\t-\n' "$name"
            fi
        done
}

# Project and local plugins would update against the cwd; managed ones belong to the org.
_CLAUDE_UPDATED_PLUGINS_JQ='def updated: select(.scope != "project" and .scope != "local" and .scope != "managed");'

_claude_plugin_versions() {
    claude plugin list --json 2>/dev/null |
        jq -r "$_CLAUDE_UPDATED_PLUGINS_JQ"' .[]? | updated | [.id, (.version // "-" | tostring)] | @tsv' 2>/dev/null
}

# _print_versions <heading> <before> <after>
_print_versions() {
    local name old new
    [ -n "$2" ] || return 0
    echo "$1"
    while IFS=$'\t' read -r name old; do
        [ -n "$name" ] || continue
        new="$(awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' <<< "$3")"
        if [ "$old" == "$new" ]; then
            echo "  $name: $old"
        else
            echo "  $name: $old -> ${new:-?}"
        fi
    done <<< "$2"
}

_upgrade_ai_tools_stages() {
    # Only the native install. HOME is resolved too, since realpath's result has no symlinks.
    if command -v claude &>/dev/null && [[ "$(realpath "$(command -v claude)")" == "$(realpath "$HOME")/.local/share/claude/"* ]]; then
        claude update || _stage_failed "claude update" "$?"
    fi

    # codex has no app, so it upgrades even while running
    _upgrade_self_updating_casks upgrade-ai-tools "${AI_CASKS[@]}" || _stage_failed "AI casks" "$?"

    # Plugins can add hooks that run as you, so show versions before and after for review.
    if command -v claude &>/dev/null; then
        local id scope version plugins rows before=""
        before="$(_claude_marketplace_versions)"
        claude plugin marketplace update || _stage_failed "claude marketplaces" "$?"
        _print_versions "Claude Code marketplaces:" "$before" "$(_claude_marketplace_versions)"
        # fd 3 keeps the terminal as stdin for claude plugin update's prompts
        if plugins="$(claude plugin list --json)" && rows="$(jq -er "$_CLAUDE_UPDATED_PLUGINS_JQ"'
            if type != "array" then error("expected a plugin list") else . end |
            map(if (.id | type) != "string" or (.scope | type) != "string" then error("invalid plugin") else . end) |
            map(updated | "\(.id)\t\(.scope)\t\(.version // "-")") |
            join("\n")' <<< "$plugins")"; then
            before=""
            while IFS=$'\t' read -r -u 3 id scope version; do
                [ -n "$id" ] || continue
                before+="$id"$'\t'"$version"$'\n'
                claude plugin update "$id" --scope "$scope" || _stage_failed "claude plugin $id" "$?"
            done 3<<< "$rows"
            _print_versions "Claude Code plugins:" "$before" "$(_claude_plugin_versions)"
        else
            _stage_failed "claude plugin list" "$?"
        fi
    fi

    # Not any t3 on PATH: the macOS app's ~/.t3/bin/t3 runs its own server and self-updates.
    if [ -x "$HOME/.local/bin/t3" ]; then
        "$HOME/.local/bin/t3" update || _stage_failed "t3 update" "$?"
    fi

    if command -v codex &>/dev/null; then
        codex plugin marketplace upgrade || _stage_failed "codex marketplaces" "$?"
    fi
}

upgrade_ai_tools() {
    local failed=()
    _upgrade_ai_tools_stages
    report_failed ${failed[@]+"${failed[@]}"}
}

upgrade() {
    local failed=()
    # apt upgrade, unlike apt-get upgrade, installs new dependencies, so kernel meta-packages aren't held back.
    if ! is_macos; then
        # shellcheck disable=SC2119 # needs no options here
        { apt_get_update && sudo apt -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" upgrade; } || _stage_failed apt "$?"
    fi

    { brew update && HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1 brew upgrade; } || _stage_failed brew "$?"
    _step_fn homebrew install_bundle || _stage_failed "brew bundle" "$?"
    _step_fn homebrew install_casks || _stage_failed casks "$?"
    if ! is_macos; then
        # Homebrew doesn't refresh fontconfig's cache for fonts it upgrades on Linux
        if command -v fc-cache &>/dev/null; then
            fc-cache -f "${XDG_DATA_HOME:-$HOME/.local/share}/fonts" || _stage_failed fc-cache "$?"
        fi
    fi
    # Ghostty updates only when it isn't running, as when upgrade runs over SSH with it closed
    _upgrade_installed_casks || _stage_failed "self-updating casks" "$?"
    if is_macos && command -v mas &>/dev/null; then
        mas upgrade || _stage_failed mas "$?"
    fi

    # After apt and brew, which upgrade ntfy. apt's own scripts restart the server.
    _step_fn ntfy restart_ntfy_notifier || _stage_failed "ntfy notifier" "$?"

    # -u alone turns on 'compatible', breaking line continuations, hence -N. vim -es exits
    # mid-update on stdin EOF, so keep stdin on the terminal.
    if [ -f ~/.vimrc ] && [ -f ~/.vim/autoload/plug.vim ]; then
        vim -Nes -u ~/.vimrc -i NONE -c 'PlugUpdate --sync' -c qa || _stage_failed "vim plugins" "$?"
    fi
    if [ -d ~/.tmux/plugins/tpm ]; then
        _step_fn tmux sync_tmux_plugins || _stage_failed "tmux plugins" "$?"
    fi

    # update_vicinae updates Vicinae and its GNOME extension; brew upgrade covers the Mac's cask
    if ! is_macos && [ -x ~/.local/bin/vicinae ]; then
        _step_fn vicinae update_vicinae || _stage_failed vicinae "$?"
    fi

    # From ~, so a project's mise.toml isn't used. PATH still has the old Node, so apply the hook
    # (--force, else it skips when no config changed) before npm.
    local node_stale=false hook rc
    if command -v mise &>/dev/null; then
        (cd ~ && mise upgrade) || _stage_failed mise "$?"
        rc=0
        hook="$(cd ~ && mise hook-env --force -s bash)" || rc=$?
        [ "$rc" -ne 0 ] || [ -n "$hook" ] || rc=1
        if [ "$rc" -eq 0 ]; then
            eval "$hook"
        else
            _stage_failed "mise hook-env" "$rc"
            node_stale=true
        fi
    fi

    if "$node_stale"; then
        echo "Skipping npm update -g, which would run the Node from before mise upgrade."
    elif command -v npm &>/dev/null; then
        npm update -g || _stage_failed npm "$?"
    fi

    if command -v uv &>/dev/null; then
        uv tool upgrade --all || _stage_failed uv "$?"
    fi

    # ~/.cargo/bin may not be on PATH
    if [ -x ~/.cargo/bin/rustup ]; then
        ~/.cargo/bin/rustup update || _stage_failed rustup "$?"
    fi

    _upgrade_ai_tools_stages

    # Last, so every old version upgraded above goes now
    brew cleanup || _stage_failed "brew cleanup" "$?"

    report_failed ${failed[@]+"${failed[@]}"}
}

main() {
    case "${1:-}" in
        "") upgrade ;;
        ai-tools) upgrade_ai_tools ;;
        *)
            echo "Usage: bash scripts/upgrade.sh [ai-tools]" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
