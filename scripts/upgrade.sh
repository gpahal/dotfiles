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
    ! _interrupted "$rc" || return "$rc"
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
# counts as running when a process has that exact name. For the others, app names can carry a
# release stage that changes, so match any running app whose name starts with the cask's app name
# up to " (". -a counts the app this shell runs in. A failed `brew outdated` or `brew info` leaves
# the cask alone and fails, since its output can't say the cask is up to date or what app it has.
# An interrupted brew command returns its status, so the caller stops.
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
        ! _interrupted "$rc" || return "$rc"
        [ "$rc" -eq 0 ] || continue
        outdated=0
        _brew_cask_outdated "$cask" --greedy || outdated=$?
        ! _interrupted "$outdated" || return "$outdated"
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
            ! _interrupted "$rc" || return "$rc"
            if [ "$rc" -ne 0 ] || ! path="$(jq -er ".casks[0] | $CASK_APP_JQ" <<< "$info")"; then
                echo "Couldn't read $cask's metadata; leaving it alone." >&2
                exit_status=1
                continue
            fi
            app="${path##*/}"
            app="${app%.app}"
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
            ! _interrupted "$status" || return "$status"
            [ "$status" -eq 0 ] || exit_status=1
        fi
    done
    return "$exit_status"
}

# Install the casks added to the homebrew step since setup last ran. Sourcing the step only defines
# its functions, but it also sets -euo pipefail, so this runs in a subshell.
_install_new_casks() (
    # Not followed: shellcheck would flag the lib/common.sh variables it sets again as lost
    # shellcheck source=/dev/null
    source "$DOTFILES_DIR/homebrew/install.sh" && install_casks
)

# Whether exit status $1 means SIGHUP, SIGINT (Ctrl-C), or SIGTERM stopped the command. brew catches
# SIGINT and exits 130, so bash itself doesn't stop. run_steps in lib/common.sh checks the same.
_interrupted() {
    [ "$1" -eq 129 ] || [ "$1" -eq 130 ] || [ "$1" -eq 143 ]
}

# Add stage $1, which exited $2, to the caller's failed array, or stop the script when it was
# interrupted
_stage_failed() {
    if _interrupted "$2"; then
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

    # CLIs installed with npm: `npm update -g` stays within the installed semver range,
    # which for 0.x versions (Codex) never reaches a new minor release
    if command -v npm &>/dev/null; then
        local pkg
        for pkg in @openai/codex @anthropic-ai/claude-code; do
            if npm ls -g --depth=0 "$pkg" &>/dev/null; then
                npm install -g "$pkg@latest" || _stage_failed "npm $pkg" "$?"
            fi
        done
    fi

    # Desktop apps installed with brew on macOS
    _upgrade_self_updating_casks upgrade-ai-tools claude chatgpt t3-code || _stage_failed "desktop apps" "$?"

    # The Codex CLI cask the codex setup step installs. `upgrade` covers it with `brew upgrade`,
    # but upgrade-ai-tools also runs on its own. It has no app, so it's upgraded even while a codex
    # process runs, as the ChatGPT app's app-server nearly always does. Replacing a CLI's binary
    # doesn't break a running copy.
    _upgrade_self_updating_casks upgrade-ai-tools codex || _stage_failed "codex cask" "$?"

    # Codex from its standalone installer: ~/.local/bin/codex links into
    # $CODEX_HOME/packages/standalone. `codex update` re-runs that installer without prompts. Only
    # run it for that install. It treats a copy from mise's npm: backend as an npm install, so it
    # would add a second copy with `npm install -g` into the current Node.
    local codex_home="${CODEX_HOME:-$HOME/.codex}"
    if command -v codex &>/dev/null && [ -d "$codex_home" ] &&
        [[ "$(realpath "$(command -v codex)")" == "$(realpath "$codex_home")/packages/standalone/"* ]]; then
        codex update || _stage_failed "codex update" "$?"
    fi

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
            failed+=("claude plugin list")
        fi
    fi

    # The t3 CLI, and the T3 Code service when one runs it
    if command -v t3 &>/dev/null; then
        t3 update || _stage_failed "t3 update" "$?"
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
    # Ubuntu's packages, including Docker's. unattended-upgrades only installs security updates.
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

    # Plugins the vim and tmux steps install, and vim-plug itself. vim -es skips the vimrc unless
    # -u names it, and -u alone turns on 'compatible', which breaks the vimrc's line continuations,
    # hence -N. Keep stdin on the terminal: vim -es exits mid-update when stdin hits end-of-file.
    if [ -f ~/.vimrc ] && [ -f ~/.vim/autoload/plug.vim ]; then
        vim -Nes -u ~/.vimrc -i NONE -c PlugUpgrade -c 'PlugUpdate --sync' -c qa || _stage_failed "vim plugins" "$?"
    fi
    if [ -x ~/.tmux/plugins/tpm/bin/update_plugins ]; then
        # A socket in a new dir, so tpm starts its own server with the repo's config, not a running
        # server's older one, as the tmux step does when it installs them
        local tmpdir status=0
        if tmpdir="$(mktemp -d)"; then
            env -u TMUX TMUX_TMPDIR="$tmpdir" ~/.tmux/plugins/tpm/bin/update_plugins all || status=$?
            rm -rf "$tmpdir"
        else
            status=1
        fi
        [ "$status" -eq 0 ] || _stage_failed "tmux plugins" "$status"
    fi

    # mise removes the Node versions upgrade moves away from once upgrade.prune_after passes (24h by
    # default), and with them any CLI installed by `npm install -g`. Install global npm CLIs with
    # mise's npm: backend instead (e.g. `mise use -g npm:<pkg>`). From ~, so a project's mise.toml
    # in the current dir neither stops it nor gets its tools upgraded.
    # This script's PATH has the Node from before the upgrade, so apply mise's hook, as from ~, and
    # npm below and upgrade_ai_tools run the Node mise just installed. --force, since the hook
    # skips its work when no config file changed.
    if command -v mise &>/dev/null; then
        (cd ~ && mise upgrade) || _stage_failed mise "$?"
        eval "$(cd ~ && mise hook-env --force -s bash)"
    fi

    if command -v npm &>/dev/null; then
        npm update -g || _stage_failed npm "$?"
    fi

    if command -v uv &>/dev/null; then
        uv tool upgrade --all || _stage_failed uv "$?"
    fi

    # rustup's installer puts it in ~/.cargo/bin, which isn't on this script's PATH when the shell
    # that ran it didn't add it
    local rustup=rustup
    [ ! -x ~/.cargo/bin/rustup ] || rustup=~/.cargo/bin/rustup
    if command -v "$rustup" &>/dev/null; then
        "$rustup" update || _stage_failed rustup "$?"
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
