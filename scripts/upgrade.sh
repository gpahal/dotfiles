#!/bin/bash
set -u

# Update everything that's installed, or with ai-tools, only the AI tools that the package manager
# upgrades miss. Each stage runs even when one before it fails, and the ones that failed are named
# at the end. zsh's `upgrade` and `upgrade-ai-tools` functions (zsh/aliases.zsh) run this script.
# No set -e, since a failed stage mustn't stop the ones after it.
# Usage: bash scripts/upgrade.sh [ai-tools]

# The shared helpers. Sourcing it only defines them and sets variables, PATH among them, and it
# sets DOTFILES_DIR to this script's repo.
# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Whether a cask is outdated: 0 when it is, 1 when it's up to date, and 2, with a message, when
# `brew outdated` fails. Given a cask, brew outdated exits 1 when it lists it, so only an exit
# above 1, or an exit 1 that lists nothing, is a failure. An interrupted brew returns its status.
# Usage: _brew_cask_outdated <cask> [<brew outdated flag>...]
_brew_cask_outdated() {
    local cask="$1" output rc=0
    shift
    output="$(brew outdated --cask "$@" --quiet "$cask" 2>/dev/null)" || rc=$?
    ! interrupted_status "$rc" || return "$rc"
    if [ "$rc" -le 1 ] && [ -n "$output" ]; then
        return 0
    elif [ "$rc" -eq 0 ]; then
        return 1
    fi
    echo "Couldn't check whether $cask is up to date: brew outdated failed." >&2
    return 2
}

# Upgrade the outdated casks given, skipping running apps, which replacing would break. Most are
# apps that update themselves, but only while they run, so this catches up the rest. `brew upgrade`
# would quit and replace them when the app bundle is behind, so `upgrade` sets
# HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS to leave them to this. A cask given as <cask>:<process>
# counts as running when a process has that exact name. For the others, an app's name can gain or
# lose a suffix in parentheses between releases, so match any running app whose name starts with the
# cask's app name up to " (". -a counts the app this shell runs in. A failed `brew outdated` or
# `brew info` leaves the cask alone and fails, since its output can't say the cask is up to date or
# what app it has. An interrupted brew command returns its status, so the caller stops. An app that
# renamed itself as it updated, as T3 Code can, would fail brew upgrade, which first removes the app
# under the name brew recorded and stops when that's gone. Such a cask is re-recorded instead,
# keeping the app on disk (_readopt_renamed_cask).
# Usage: _upgrade_self_updating_casks <command to re-run> <cask>[:<process>]...
_upgrade_self_updating_casks() {
    local rerun="$1" entry cask process info path app running outdated status rc exit_status=0
    shift
    for entry in "$@"; do
        cask="${entry%%:*}"
        process=""
        [ "$cask" == "$entry" ] || process="${entry#*:}"
        rc=0
        brew list --cask "$cask" &>/dev/null || rc=$?
        ! interrupted_status "$rc" || return "$rc"
        [ "$rc" -eq 0 ] || continue
        outdated=0
        _brew_cask_outdated "$cask" --greedy || outdated=$?
        ! interrupted_status "$outdated" || return "$outdated"
        [ "$outdated" -ne 2 ] || exit_status=1
        [ "$outdated" -eq 0 ] || continue
        running=false
        if [ -n "$process" ]; then
            app="$cask"
            ! pgrep -x "$process" &>/dev/null || running=true
        else
            # A failed brew info, or output jq can't parse, mustn't pass for a cask with no app,
            # whose path is empty. -e also fails on empty output.
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
            # A cask with no app artifact has no name to check. Logi Options+, which keeps an
            # agent running, quits the app and agents in its uninstall steps before the upgrade,
            # and a CLI such as codex keeps running from the old binary.
            if [ -n "$app" ] && pgrep -af "^${path%/*}/${app}[^/]*\.app/Contents/MacOS/" &>/dev/null; then
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

# Print the app path brew recorded when it installed cask $1, in the dir of the app path $2 the
# cask now gives. Fails when brew's install receipt names no app, or the cask's uninstall does
# more than remove its app, which _readopt_renamed_cask's uninstall would then run.
_recorded_cask_app() {
    local receipt name
    receipt="$(brew --caskroom 2>/dev/null)/$1/.metadata/INSTALL_RECEIPT.json"
    name="$(jq -er '.uninstall_artifacts
        | if all(.[]; type == "object" and (keys - ["app", "zap", "target"] | length == 0))
          then [.[] | select(has("app")) | .target // (.app[1].target? // .app[0])][0]
          else empty end
        | strings' "$receipt" 2>/dev/null)" || return 1
    case "$name" in
        /*) echo "$name" ;;
        *) echo "${2%/*}/$name" ;;
    esac
}

# Succeeds when the app brew recorded for cask $1 is gone but the app at $2, which the cask now
# gives, is there: the app renamed itself as it updated
_cask_app_renamed() {
    local recorded
    recorded="$(_recorded_cask_app "$1" "$2")" || return 1
    [ "$recorded" != "$2" ] && [ ! -e "$recorded" ] && [ -d "$2" ]
}

# Re-record cask $1, whose app renamed itself to $2 as it updated: uninstall the stale record,
# which has no app left to remove, then install the cask adopting the app in place, so a running
# app is left alone. A self-updating cask's adopt takes the app whatever its version.
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

# Install the casks added to the homebrew step since setup last ran. Sourcing the step only defines
# its functions, but it also sets -euo pipefail, so this runs in a subshell.
_install_new_casks() (
    # Not followed: shellcheck would flag the lib/common.sh variables it sets again as lost
    # shellcheck source=/dev/null
    source "$DOTFILES_DIR/homebrew/install.sh" && install_casks
)

# Add stage $1, which exited $2, to the caller's failed array, or stop the script when it was
# interrupted
_stage_failed() {
    if interrupted_status "$2"; then
        echo "Interrupted; stopping." >&2
        exit "$2"
    fi
    failed+=("$1")
}

# Print the stages of upgrade or upgrade-ai-tools that failed, and fail, as setup.sh does for its
# steps, so a failure early on doesn't scroll away behind the stages after it
_upgrade_report() {
    [ "$#" -gt 0 ] || return 0
    echo "Failed: $(printf '%s\n' "$@" | join_lines ', ')" >&2
    return 1
}

# Update AI tools that the package manager upgrades miss
upgrade_ai_tools() {
    local failed=()
    # Claude Code's native install (~/.local/share/claude) updates through `claude update`. HOME
    # is resolved too, since the path claude resolves to has no symlinks in it.
    if command -v claude &>/dev/null && [[ "$(realpath "$(command -v claude)")" == "$(realpath "$HOME")/.local/share/claude/"* ]]; then
        claude update || _stage_failed "claude update" "$?"
    fi

    # Desktop apps installed with brew on macOS
    _upgrade_self_updating_casks upgrade-ai-tools claude chatgpt t3-code || _stage_failed "desktop apps" "$?"

    # The Codex CLI cask the codex setup step installs. `upgrade` covers it with `brew upgrade`,
    # but upgrade-ai-tools also runs on its own. It has no app, so it's upgraded even while a codex
    # process runs, as the ChatGPT app's app-server nearly always does. Replacing a CLI's binary
    # doesn't break a running copy.
    _upgrade_self_updating_casks upgrade-ai-tools codex || _stage_failed "codex cask" "$?"

    # Plugins are separate from the CLIs above. Claude Code has no update-all, so update
    # each installed plugin in the scope it was installed in. Updates apply on next start.
    if command -v claude &>/dev/null; then
        claude plugin marketplace update || _stage_failed "claude marketplaces" "$?"
        local id scope plugins rows
        # Read the list on fd 3 so `claude plugin update` keeps the terminal as stdin for its
        # prompts. Skip project and local plugins, which would update against the current directory,
        # and managed ones, which your organization's settings control.
        if plugins="$(claude plugin list --json)" && rows="$(jq -er '
            if type != "array" then error("expected a plugin list") else . end |
            map(if (.id | type) != "string" or (.scope | type) != "string" then error("invalid plugin") else . end) |
            map(select(.scope != "project" and .scope != "local" and .scope != "managed") | "\(.id)\t\(.scope)") |
            join("\n")' <<< "$plugins")"; then
            while IFS=$'\t' read -r -u 3 id scope; do
                [ -n "$id" ] || continue
                claude plugin update "$id" --scope "$scope" || _stage_failed "claude plugin $id" "$?"
            done 3<<< "$rows"
        else
            _stage_failed "claude plugin list" "$?"
        fi
    fi

    # The t3 CLI the t3-code step installs, and the T3 Code service when one runs it. Not any t3 on
    # PATH: the macOS app writes ~/.t3/bin/t3, which runs the app's own server, and the app updates
    # itself.
    if [ -x "$HOME/.local/bin/t3" ]; then
        "$HOME/.local/bin/t3" update || _stage_failed "t3 update" "$?"
    fi

    # Codex's bundled marketplaces ship with the CLI and update with it. With no name,
    # this refreshes any Git marketplace added on top of them.
    if command -v codex &>/dev/null; then
        codex plugin marketplace upgrade || _stage_failed "codex marketplaces" "$?"
    fi

    _upgrade_report ${failed[@]+"${failed[@]}"}
}

# Update everything that's installed
upgrade() {
    local failed=()
    # Ubuntu's packages. unattended-upgrades installs only security, Chrome, and Docker updates.
    # apt upgrade, unlike apt-get upgrade, installs new dependencies, so upgrades that need them
    # (such as the kernel meta-packages) aren't held back. Both wait for the locks that apt-daily
    # and unattended-upgrades hold after boot.
    if [[ "$OSTYPE" == linux* ]]; then
        # shellcheck disable=SC2119 # it passes options on to apt-get update, and needs none here
        { apt_get_update && sudo apt -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" upgrade; } || _stage_failed apt "$?"
    fi

    { brew update && HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1 brew upgrade; } || _stage_failed brew "$?"
    # Formulae added to this repo's Brewfile since setup last ran. brew bundle check also fails on
    # a missing App Store app, which install can't fix without an App Store sign-in, so both skip
    # the Brewfile's App Store apps, by id, as the homebrew step's check does. The mas stage below
    # updates the apps.
    local brewfile="$DOTFILES_DIR/homebrew/Brewfile" mas_ids
    mas_ids="$(mas_app_ids "$brewfile" | tr '\n' ' ')"
    if ! HOMEBREW_BUNDLE_MAS_SKIP="$mas_ids" brew bundle check --file="$brewfile" --no-upgrade &>/dev/null; then
        HOMEBREW_BUNDLE_MAS_SKIP="$mas_ids" brew bundle install --file="$brewfile" --no-upgrade ||
            _stage_failed "brew bundle" "$?"
    fi
    _install_new_casks || _stage_failed casks "$?"
    brew cleanup || _stage_failed "brew cleanup" "$?"
    if [[ "$OSTYPE" == linux* ]]; then
        # Homebrew doesn't refresh fontconfig's cache for the fonts it upgrades on Linux, which go
        # where it put them: under XDG_DATA_HOME when that's set
        if command -v fc-cache &>/dev/null; then
            fc-cache -f "${XDG_DATA_HOME:-$HOME/.local/share}/fonts" || _stage_failed fc-cache "$?"
        fi
        # brew upgrade skips Zed's cask here too, and its own updater is off
        _upgrade_self_updating_casks upgrade zed:zed-editor || _stage_failed "self-updating casks" "$?"
    else
        # Casks marked as updating themselves that brew upgrade skips. Zed's settings.json turns
        # its updater off, and the others rarely run, so their own updaters rarely catch up.
        _upgrade_self_updating_casks upgrade zed appcleaner the-unarchiver logi-options+ || _stage_failed "self-updating casks" "$?"
        # Every App Store app, not just the Brewfile's. mas asks for your password to update one.
        if command -v mas &>/dev/null; then
            mas upgrade || _stage_failed mas "$?"
        fi
    fi

    # The plugins the vim and tmux steps install, each moved to the commit the repo pins and never
    # past it; just bump-plugins moves the pins. vim-plug itself stays the version the vim step
    # installs. vim -es skips the vimrc unless -u names it, and -u alone turns on 'compatible',
    # which breaks the vimrc's line continuations, hence -N. Keep stdin on the terminal: vim -es
    # exits mid-update when stdin hits end-of-file.
    if [ -f ~/.vimrc ] && [ -f ~/.vim/autoload/plug.vim ]; then
        vim -Nes -u ~/.vimrc -i NONE -c 'PlugUpdate --sync' -c qa || _stage_failed "vim plugins" "$?"
    fi
    # In its own bash, since the step's script sets its own shell options and sources lib/common.sh
    # again
    if [ -d ~/.tmux/plugins/tpm ]; then
        # shellcheck disable=SC2016 # expanded by the inner bash
        "$BASH" -c 'source "$1/tmux/install.sh" && sync_tmux_plugins' bash "$DOTFILES_DIR" ||
            _stage_failed "tmux plugins" "$?"
    fi

    # mise removes the Node versions upgrade moves away from once upgrade.prune_after passes (24h by
    # default), and with them any CLI installed by `npm install -g`. Install global npm CLIs with
    # mise's npm: backend instead (e.g. `mise use -g npm:<pkg>`). From ~, so a project's mise.toml
    # in the current dir neither stops it nor gets its tools upgraded.
    # This script's PATH has the Node from before the upgrade, so apply mise's hook, as from ~, and
    # npm below runs the Node mise just installed. --force, since the hook skips its work when no
    # config file changed.
    # When the hook fails, or prints nothing, npm would run the old Node, so it's skipped.
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

    # The runtimes step installs rustup in ~/.cargo/bin, which isn't on this script's PATH when the
    # shell that ran it didn't add it
    if [ -x ~/.cargo/bin/rustup ]; then
        ~/.cargo/bin/rustup update || _stage_failed rustup "$?"
    fi

    upgrade_ai_tools || _stage_failed upgrade-ai-tools "$?"

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
