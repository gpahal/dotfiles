#!/bin/bash
set -euo pipefail

# Install Node LTS and Go with mise, and Rust with rustup.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# The global config file, which mise use --global writes to
mise_global_config() {
    echo "${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
}

# Print a tool's version from the global mise config, or nothing when the file or the key is
# missing. Fails, with mise's error on stderr, when mise can't read the file. The file is named,
# since --global could read another one. Every mise command here runs from $HOME: mise refuses to
# run in a project with an untrusted mise.toml, and would add a trusted one's tools.
global_tool_version() {
    local file errors value
    file="$(mise_global_config)"
    [ -f "$file" ] || return 0
    errors="$(mktemp)" || return 1
    if value="$(cd "$HOME" && mise config get -f "$file" "tools.$1" 2> "$errors")"; then
        printf '%s\n' "$value"
    elif ! grep -q 'Key not found' "$errors"; then
        cat "$errors" >&2
        rm -f "$errors"
        return 1
    fi
    rm -f "$errors"
}

# The global versions setup sets, as tool@version. Each is a value you can change
# (replace_custom_value): one you set yourself is kept unless you agree to replace it.
MISE_GLOBALS=(node@lts go@latest)

# Succeeds when every tool the configs active in $HOME list is installed: the global config, plus
# ~/mise.toml or ~/.tool-versions, which mise install below installs too, since it also runs from
# $HOME. Offline, so mise reads its cached version lists instead of refreshing them. stdout lists
# the missing tools. A version mise can't resolve offline (such as go@latest with no go installed)
# is only a warning on stderr, and mise still exits 0, so that warning counts as missing too, but
# other warnings don't.
mise_tools_installed() {
    local output errors missing=false
    errors="$(mktemp)"
    output="$(cd "$HOME" && MISE_OFFLINE=1 mise ls --missing 2> "$errors")" || missing=true
    if [ -n "$output" ] || grep -q 'Failed to resolve' "$errors"; then
        missing=true
    fi
    rm -f "$errors"
    ! "$missing"
}

# rustup's installer puts it here, which may not be on PATH yet
rustup_installed() {
    [ -x "$HOME/.cargo/bin/rustup" ]
}

run_rustup() {
    "$HOME/.cargo/bin/rustup" "$@"
}

# Query the default directly: a project's override must not conceal an incomplete global setup.
rust_default() {
    run_rustup default 2>/dev/null | awk 'NR == 1 {print $1}'
}

rust_ready() {
    local toolchain
    toolchain="$(rust_default)" && [ -n "$toolchain" ] &&
        run_rustup run "$toolchain" rustc --version &>/dev/null &&
        run_rustup run "$toolchain" cargo --version &>/dev/null
}

status() {
    if status_require_cmd mise "Node and Go"; then
        local tool current
        for tool in "${MISE_GLOBALS[@]}"; do
            if current="$(global_tool_version "${tool%@*}" 2> /dev/null)"; then
                status_custom_value "mise's global ${tool%@*}" "$current" "${tool#*@}"
            else
                status_item unknown "mise's global ${tool%@*}: couldn't read $(mise_global_config)"
            fi
        done
        status_check "The tools mise's configs in ~ list installed" mise_tools_installed
    fi
    status_check "rustup" rustup_installed
    status_check "Rust default toolchain (rustc and cargo)" rust_ready
    status_result
}

apply() {
    echo "Installing language runtimes via mise..."
    require_cmd mise || return 1
    # The rustup installer is downloaded with curl
    rustup_installed || require_cmd curl || return 1
    # A failed mise command fails the step, after Rust is set up too
    local status=0 tool current set=() already=() unread=false
    for tool in "${MISE_GLOBALS[@]}"; do
        if ! current="$(global_tool_version "${tool%@*}")"; then
            unread=true
            continue
        fi
        if [ "$current" == "${tool#*@}" ]; then
            already+=("$tool")
        elif replace_custom_value "mise's global ${tool%@*}" "$current" "${tool#*@}"; then
            set+=("$tool")
        fi
    done
    if "$unread"; then
        echo "  Couldn't read mise's global config, $(mise_global_config), so the step changes neither global." >&2
        set=()
        status=1
    fi
    if [ ${#already[@]} -eq ${#MISE_GLOBALS[@]} ]; then
        echo "mise's global node and go are already set."
    else
        # replace_custom_value named the kept ones
        for tool in ${already[@]+"${already[@]}"}; do
            echo "mise's global ${tool%@*} is already ${tool#*@}."
        done
    fi
    if [ ${#set[@]} -gt 0 ]; then
        if (cd "$HOME" && mise use --global "${set[@]}"); then
            for tool in "${set[@]}"; do
                echo "Set mise's global ${tool%@*} to ${tool#*@}."
            done
        else
            status=1
        fi
    fi
    # The config can be in place while a tool isn't installed, e.g. after a failed download or a
    # config copied from another machine. --quiet hides the progress display, which mise shows
    # even when there's nothing to install.
    (cd "$HOME" && mise install --quiet) || status=1
    [ "$status" -eq 0 ] || echo "  mise failed to set up Node and Go. Fix the errors above and re-run." >&2

    # Rust is managed by rustup directly rather than mise, so projects' rust-toolchain.toml files
    # are respected
    if rustup_installed; then
        echo "rustup already installed."
        if ! rust_ready; then
            local toolchain
            toolchain="$(rust_default || true)"
            if [ -n "$toolchain" ]; then
                echo "Repairing Rust's default toolchain, $toolchain..."
                run_rustup toolchain install "$toolchain" --component rustc --component cargo || status=1
            else
                echo "Installing Rust's stable default toolchain..."
                run_rustup default stable || status=1
            fi
        fi
    else
        echo "Installing rustup..."
        # --no-modify-path: the zsh step puts ~/.cargo/bin on PATH for every kind of shell, and the
        # ubuntu step for user services
        run_installer sh https://sh.rustup.rs "the rustup installer" -y --no-modify-path || status=1
    fi
    if ! rust_ready; then
        echo "  Rust's default toolchain is incomplete. Check rustup show and re-run this step." >&2
        status=1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
