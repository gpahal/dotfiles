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

_cask_listed() {
    awk -F / -v cask="$1" '$NF == cask { found = 1 } END { exit !found }'
}

# Upgrade outdated casks, skipping running apps, which replacing would break.
# An app's name can gain or lose a " (...)" suffix between releases, so match up to " (".
# Usage: _upgrade_self_updating_casks <command to re-run> <cask>[:<process>]...
_upgrade_self_updating_casks() {
    local rerun="$1" entry cask process info path app running installed outdated one status rc
    local exit_status=0 listed=() names=()
    shift
    rc=0
    installed="$(brew list --cask -1 2>/dev/null)" || rc=$?
    ! interrupted_status "$rc" || return "$rc"
    if [ "$rc" -ne 0 ]; then
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
    rc=0
    outdated="$(_brew_casks_outdated "${names[@]}")" || rc=$?
    ! interrupted_status "$rc" || return "$rc"
    if [ "$rc" -ne 0 ]; then
        # One unknown cask fails the whole query, so ask each alone
        outdated=""
        for cask in "${names[@]}"; do
            rc=0
            one="$(_brew_casks_outdated "$cask")" || rc=$?
            ! interrupted_status "$rc" || return "$rc"
            if [ "$rc" -eq 0 ]; then
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
            # A failed brew info mustn't pass for a cask with no app (empty path)
            rc=0
            info="$(brew info --json=v2 --cask "$cask")" || rc=$?
            ! interrupted_status "$rc" || return "$rc"
            if [ "$rc" -ne 0 ] || ! path="$(jq -er ".casks[0] | $CASK_APP_JQ" <<< "$info")"; then
                echo "Couldn't read $cask's metadata; leaving it alone." >&2
                exit_status=1
                continue
            fi
            app="${path##*/}"
            app="${app%.app}"
            if [ -n "$app" ] && _cask_app_renamed "$cask" "$path"; then
                status=0
                _readopt_renamed_cask "$cask" "$path" || status=$?
                ! interrupted_status "$status" || return "$status"
                [ "$status" -eq 0 ] || exit_status=1
                continue
            fi
            app="${app%% (*}"
            # -a: macOS pgrep otherwise skips its own ancestors, such as the app this shell runs in
            if [ -n "$app" ] && pgrep -af "^$(regex_escape "${path%/*}/$app")[^/]*\.app/Contents/MacOS/" &>/dev/null; then
                running=true
            fi
        fi
        if "$running"; then
            echo "$app is running; quit it and run $rerun again to update it."
        else
            status=0
            brew upgrade --cask --greedy "$cask" || status=$?
            ! interrupted_status "$status" || return "$status"
            [ "$status" -eq 0 ] || exit_status=1
        fi
    done
    return "$exit_status"
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

# Subshell, since the step sets -euo pipefail
_homebrew_step() (
    # Not followed: shellcheck would flag lib/common.sh's variables as lost
    # shellcheck source=/dev/null
    source "$DOTFILES_DIR/homebrew/install.sh" && "$1"
)

_stage_failed() {
    if interrupted_status "$2"; then
        echo "Interrupted; stopping." >&2
        exit "$2"
    fi
    failed+=("$1")
}

_upgrade_report() {
    [ "$#" -gt 0 ] || return 0
    echo "Failed: $(printf '%s\n' "$@" | join_lines ', ')" >&2
    return 1
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

    # codex has no app, so it upgrades even while running; replacing a CLI binary is safe.
    _upgrade_self_updating_casks upgrade-ai-tools claude chatgpt t3-code codex || _stage_failed "AI casks" "$?"

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
    _upgrade_report ${failed[@]+"${failed[@]}"}
}

upgrade() {
    local failed=()
    # apt upgrade, unlike apt-get upgrade, installs new dependencies, so kernel meta-packages aren't held back.
    if ! is_macos; then
        # shellcheck disable=SC2119 # needs no options here
        { apt_get_update && sudo apt -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" upgrade; } || _stage_failed apt "$?"
    fi

    { brew update && HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1 brew upgrade; } || _stage_failed brew "$?"
    _homebrew_step install_bundle || _stage_failed "brew bundle" "$?"
    _homebrew_step install_casks || _stage_failed casks "$?"
    if ! is_macos; then
        # Homebrew doesn't refresh fontconfig's cache for fonts it upgrades on Linux
        if command -v fc-cache &>/dev/null; then
            fc-cache -f "${XDG_DATA_HOME:-$HOME/.local/share}/fonts" || _stage_failed fc-cache "$?"
        fi
        # brew upgrade skips Zed, and its own updater is off
        _upgrade_self_updating_casks upgrade zed:zed-editor || _stage_failed "self-updating casks" "$?"
    else
        # brew upgrade skips these; Zed's updater is off and the others rarely run.
        _upgrade_self_updating_casks upgrade zed appcleaner the-unarchiver logi-options+ || _stage_failed "self-updating casks" "$?"
        if command -v mas &>/dev/null; then
            mas upgrade || _stage_failed mas "$?"
        fi
    fi

    # -u alone turns on 'compatible', breaking line continuations, hence -N. vim -es exits
    # mid-update on stdin EOF, so keep stdin on the terminal.
    if [ -f ~/.vimrc ] && [ -f ~/.vim/autoload/plug.vim ]; then
        vim -Nes -u ~/.vimrc -i NONE -c 'PlugUpdate --sync' -c qa || _stage_failed "vim plugins" "$?"
    fi
    # Own bash, since the step sets shell options and re-sources lib/common.sh
    if [ -d ~/.tmux/plugins/tpm ]; then
        # shellcheck disable=SC2016 # expanded by the inner bash
        "$BASH" -c 'source "$1/tmux/install.sh" && sync_tmux_plugins' bash "$DOTFILES_DIR" ||
            _stage_failed "tmux plugins" "$?"
    fi

    # Vicinae's installer moves it to the latest release; extensions.gnome.org has its extension
    if ! is_macos && [ -x ~/.local/bin/vicinae ]; then
        # shellcheck disable=SC2016 # expanded by the inner bash
        "$BASH" -c 'source "$1/vicinae/install.sh" && update_vicinae' bash "$DOTFILES_DIR" ||
            _stage_failed vicinae "$?"
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

    _upgrade_report ${failed[@]+"${failed[@]}"}
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
