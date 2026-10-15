#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The runtimes step sets mise's globals when they're unset, asks before replacing ones you set,
# installs rustup only when ~/.cargo/bin/rustup isn't there, sets or repairs Rust's default
# toolchain, and still sets up Rust when mise fails, then fails. Without mise it fails before
# installing anything. mise, and curl, which fetches the rustup installer, are stubbed.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script runtimes/install.sh
# Hide any real mise and rustup
export PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
export GLOBALS_FILE="$SANDBOX/mise-globals"
export RUST_DEFAULT="$SANDBOX/rust-default" RUST_HEALTHY="$SANDBOX/rust-healthy"
stub rustup 'case "$1" in
    default)
        if [ $# -eq 1 ]; then cat "$RUST_DEFAULT"; else
            [ "${RUST_FAIL:-}" != 1 ] || exit 1
            echo "$2" > "$RUST_DEFAULT"; touch "$RUST_HEALTHY"
        fi ;;
    run) [ -f "$RUST_HEALTHY" ] ;;
    toolchain)
        [ "${RUST_FAIL:-}" != 1 ] || exit 1
        touch "$RUST_HEALTHY" ;;
esac'
export RUST_STUB="$SANDBOX/rustup-stub"
mv "$STUB_DIR/rustup" "$RUST_STUB"

# The globals are set when $GLOBALS_FILE exists. mise config get must read the global config by
# file, $MISE_CONFIG_FILE, and fails as mise does for an unset key, or with MISE_CONFIG_ERR=1, as
# for a file it can't parse. MISE_FAIL=use or MISE_FAIL=install fails that command. mise ls prints
# $MISE_LS_OUT on stdout and $MISE_LS_ERR on stderr. Each call also logs the dir it ran in.
export MISE_CONFIG_FILE="$HOME/.config/mise/config.toml"
mkdir -p "$HOME/.config/mise"
touch "$MISE_CONFIG_FILE"
# shellcheck disable=SC2016 # expanded by the stub
stub mise 'echo "mise-cwd $PWD" >> "$STUB_LOG"
case "$1 ${2:-}" in
    "config get")
        if [ "$3" != -f ] || [ "$4" != "$MISE_CONFIG_FILE" ]; then
            echo "mise config get read the wrong file" >> "$STUB_LOG"
            exit 2
        fi
        if [ -n "${MISE_CONFIG_ERR:-}" ]; then
            echo "mise ERROR TOML parse error at line 1, column 5" >&2
            exit 1
        fi
        # MISE_NODE and MISE_GO stand in for a version you set yourself
        case "$5" in tools.node) v="${MISE_NODE:-}" ;; tools.go) v="${MISE_GO:-}" ;; esac
        if [ -z "$v" ]; then
            if [ ! -f "$GLOBALS_FILE" ]; then
                echo "mise ERROR Key not found: $5 in $4" >&2
                exit 1
            fi
            case "$5" in tools.node) v=lts ;; tools.go) v=latest ;; esac
        fi
        echo "$v" ;;
    "use --global") [ "${MISE_FAIL:-}" != use ] || exit 1 ;;
    "install --quiet") [ "${MISE_FAIL:-}" != install ] || exit 1 ;;
    "ls --missing")
        [ -z "${MISE_LS_OUT:-}" ] || echo "$MISE_LS_OUT"
        [ -z "${MISE_LS_ERR:-}" ] || echo "$MISE_LS_ERR" >&2 ;;
esac'
# Writes an installer that logs its arguments to the file after -o
# shellcheck disable=SC2016
stub curl 'while [ $# -gt 0 ]; do
    if [ "$1" == -o ]; then
        echo "echo \"rustup-init \$*\" >> \"\$STUB_LOG\"" > "$2"
        cat >> "$2" <<"INSTALL"
mkdir -p "$HOME/.cargo/bin"
cp "$RUST_STUB" "$HOME/.cargo/bin/rustup"
echo stable > "$RUST_DEFAULT"
touch "$RUST_HEALTHY"
INSTALL
    fi
    shift
done'

# Globals already set, rustup missing: no mise use, and rustup installs
touch "$GLOBALS_FILE"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "mise's global node and go are already set."
assert_file_not_contains "$STUB_LOG" "mise use"
assert_file_contains "$STUB_LOG" "mise install --quiet"
assert_file_contains "$STUB_LOG" "rustup-init -y --no-modify-path"

# A tool missing from the globals: mise use sets them. Run from a project with an untrusted
# mise.toml, every mise command runs in $HOME, so mise neither refuses nor adds the project's tools.
: > "$STUB_LOG"
rm "$GLOBALS_FILE"
mkdir -p "$SANDBOX/project"
echo '[tools]' > "$SANDBOX/project/mise.toml"
cd "$SANDBOX/project"
assert_exit 0 main
cd "$HOME"
assert_file_contains "$STUB_LOG" "mise use --global node@lts go@latest"
assert_eq "" "$(grep '^mise-cwd ' "$STUB_LOG" | grep -vxF "mise-cwd $HOME" || true)" "dirs mise ran in"
grep -q '^mise-cwd ' "$STUB_LOG" || fail "the mise stub didn't log its dir"

# A global you set yourself is a value you can change: without a terminal it's kept, and status
# names it. With one, setup asks every run, and replaces it on yes. DOTFILES_ASSUME_YES=1 answers
# yes. A global that's unset is set without asking, and one that's the repo's is left alone.
touch "$GLOBALS_FILE"
: > "$STUB_LOG"
export MISE_NODE=22
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Kept your value for mise's global node, 22. The repo's is lts."
assert_contains "$RUN_OUTPUT" "mise's global go is already latest."
assert_not_contains "$RUN_OUTPUT" "node and go are already set"
assert_file_not_contains "$STUB_LOG" "mise use"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         mise's global node: yours, 22 (the repo's is lts)"
assert_contains "$RUN_OUTPUT" "ok         mise's global go: latest"
# Asked with a terminal: no keeps it, yes replaces only that tool
is_interactive() { true; }
confirm() {
    local reply
    echo "$1"
    read -r reply
    [ "$reply" == y ]
}
: > "$STUB_LOG"
assert_exit 0 main <<< n
assert_contains "$RUN_OUTPUT" "mise's global node is 22, not the repo's lts. Replace it?"
assert_file_not_contains "$STUB_LOG" "mise use"
assert_exit 0 main <<< y
assert_file_contains "$STUB_LOG" "mise use --global node@lts"
assert_file_not_contains "$STUB_LOG" "go@latest"
# lib/common.sh brings back the real confirm and is_interactive
load_script lib/common.sh
export PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_file_contains "$STUB_LOG" "mise use --global node@lts"
# Unset: set without a question, alongside a kept custom value
rm "$GLOBALS_FILE"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "mise use --global go@latest"
assert_file_not_contains "$STUB_LOG" "node@lts"
assert_contains "$RUN_OUTPUT" "Set mise's global go to latest."
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    mise's global go: not set; the repo's is latest"
unset MISE_NODE

# The same for go: kept without a terminal, kept on no, replaced on yes and with
# DOTFILES_ASSUME_YES=1
touch "$GLOBALS_FILE"
export MISE_GO=1.22
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Kept your value for mise's global go, 1.22. The repo's is latest."
assert_contains "$RUN_OUTPUT" "mise's global node is already lts."
assert_file_not_contains "$STUB_LOG" "mise use"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         mise's global go: yours, 1.22 (the repo's is latest)"
is_interactive() { true; }
confirm() {
    local reply
    echo "$1"
    read -r reply
    [ "$reply" == y ]
}
: > "$STUB_LOG"
assert_exit 0 main <<< n
assert_contains "$RUN_OUTPUT" "mise's global go is 1.22, not the repo's latest. Replace it?"
assert_file_not_contains "$STUB_LOG" "mise use"
assert_exit 0 main <<< y
assert_file_contains "$STUB_LOG" "mise use --global go@latest"
assert_file_not_contains "$STUB_LOG" "node@lts"
load_script lib/common.sh
export PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_file_contains "$STUB_LOG" "mise use --global go@latest"
unset MISE_GO
rm "$GLOBALS_FILE"

# MISE_GLOBAL_CONFIG_FILE names the global config, which is read by file
touch "$GLOBALS_FILE" "$SANDBOX/global.toml"
: > "$STUB_LOG"
MISE_GLOBAL_CONFIG_FILE="$SANDBOX/global.toml" MISE_CONFIG_FILE="$SANDBOX/global.toml" assert_exit 0 main
assert_contains "$RUN_OUTPUT" "mise's global node and go are already set."
assert_file_not_contains "$STUB_LOG" "wrong file"
# With no global config yet, both are unset, and mise use sets them
mv "$MISE_CONFIG_FILE" "$SANDBOX/config.toml.aside"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "mise use --global node@lts go@latest"
assert_file_not_contains "$STUB_LOG" "mise config get"
mv "$SANDBOX/config.toml.aside" "$MISE_CONFIG_FILE"
# An error other than an unset key, such as a file mise can't parse, fails the step without
# setting either global, and gives status unknown
: > "$STUB_LOG"
MISE_CONFIG_ERR=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "TOML parse error"
assert_contains "$RUN_OUTPUT" "Couldn't read mise's global config"
assert_file_not_contains "$STUB_LOG" "mise use"
MISE_CONFIG_ERR=1 run status
assert_contains "$RUN_OUTPUT" "unknown    mise's global node: couldn't read $MISE_CONFIG_FILE"
rm "$GLOBALS_FILE"

# mise fails: rustup still installs, and the step fails
for cmd in use install; do
    : > "$STUB_LOG"
    rm -rf "$HOME/.cargo"
    MISE_FAIL="$cmd" assert_exit 1 main
    assert_file_contains "$STUB_LOG" "rustup-init -y --no-modify-path"
done
assert_contains "$RUN_OUTPUT" "mise"

# rustup already installed: no installer
: > "$STUB_LOG"
touch "$GLOBALS_FILE"
mkdir -p "$HOME/.cargo/bin"
cp "$RUST_STUB" "$HOME/.cargo/bin/rustup"
chmod +x "$HOME/.cargo/bin/rustup"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "rustup already installed."
assert_file_not_contains "$STUB_LOG" "rustup-init"
assert_file_not_contains "$STUB_LOG" "curl"

# A manager with no default must recover Rust; a custom usable default stays selected.
rm "$RUST_DEFAULT" "$RUST_HEALTHY"
assert_exit 3 status
assert_exit 0 main
assert_file_contains "$STUB_LOG" 'rustup default stable'
assert_exit 0 status
echo custom > "$RUST_DEFAULT"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq custom "$(cat "$RUST_DEFAULT")" "custom Rust default"
assert_file_not_contains "$STUB_LOG" 'toolchain install'
# A selected but incomplete toolchain is repaired; a failed repair fails the step.
rm "$RUST_HEALTHY"
RUST_FAIL=1 assert_exit 1 main
assert_exit 0 main
assert_file_contains "$STUB_LOG" 'rustup toolchain install custom'

# A warning alone doesn't mean a tool is missing, but a version mise can't resolve does
MISE_LS_ERR="mise WARN  some deprecation" assert_exit 0 mise_tools_installed
MISE_LS_OUT="node  24 (missing)  ~/.config/mise/config.toml  lts" assert_exit 1 mise_tools_installed
MISE_LS_ERR="mise WARN  Failed to resolve tool version list for go: no versions found for go" \
    assert_exit 1 mise_tools_installed
assert_exit 0 mise_tools_installed
# It checks every config active in $HOME, not only the global one, since mise install there
# installs them all, ~/mise.toml and ~/.tool-versions included
: > "$STUB_LOG"
MISE_LS_OUT="python  3.13 (missing)  ~/mise.toml  3.13" assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    The tools mise's configs in ~ list installed"
assert_file_contains "$STUB_LOG" "mise ls --missing"
assert_file_not_contains "$STUB_LOG" "mise ls --missing --global"

# Only rustup's installer's copy in ~/.cargo/bin counts, not one elsewhere on PATH
rm "$HOME/.cargo/bin/rustup"
cp "$RUST_STUB" "$STUB_DIR/rustup"
assert_exit 1 rustup_installed
rm "$STUB_DIR/rustup"

# A missing mise fails the step before it installs anything
rm "$STUB_DIR/mise"
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "mise"
assert_file_not_contains "$STUB_LOG" "rustup-init"
test_done
