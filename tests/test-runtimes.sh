#!/bin/bash
# shellcheck disable=SC2329

# The runtimes step; test-step-prereqs.sh covers it without mise.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script runtimes/install.sh
export PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
export GLOBALS_FILE="$SANDBOX/mise-globals"
export RUST_DEFAULT="$SANDBOX/rust-default" RUST_HEALTHY="$SANDBOX/rust-healthy"
export RUST_STUB="$SANDBOX/rustup-stub"
stub_at "$RUST_STUB" 'case "$1" in
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

export EXPECTED_MISE_CONFIG="$HOME/.config/mise/config.toml"
mkdir -p "$HOME/.config/mise"
touch "$EXPECTED_MISE_CONFIG"
stub mise 'echo "mise-cwd $PWD" >> "$STUB_LOG"
case "$1 ${2:-}" in
    "config get")
        if [ "$3" != -f ] || [ "$4" != "$EXPECTED_MISE_CONFIG" ]; then
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
        [ -z "${MISE_LS_OUT:-}" ] || echo "$MISE_LS_OUT" ;;
esac'
cat > "$SANDBOX/rustup-init" << 'INSTALL'
echo "rustup-init $*" >> "$STUB_LOG"
mkdir -p "$HOME/.cargo/bin"
cp "$RUST_STUB" "$HOME/.cargo/bin/rustup"
echo stable > "$RUST_DEFAULT"
touch "$RUST_HEALTHY"
INSTALL
stub_fetch "https://sh.rustup.rs=$SANDBOX/rustup-init"

touch "$GLOBALS_FILE"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "mise use"
assert_file_contains "$STUB_LOG" "mise install --quiet"
assert_file_contains "$STUB_LOG" "rustup-init -y --no-modify-path"

# Every mise command runs in $HOME, so a project's untrusted mise.toml neither blocks nor adds tools
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

# A global you set is kept without a terminal, and asked about with one
touch "$GLOBALS_FILE"
: > "$STUB_LOG"
export MISE_NODE=22
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "mise use"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         mise's global node: yours, 22 (the repo's is lts)"
: > "$STUB_LOG"
answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "mise's global node is 22, not the repo's lts. Replace it?"
assert_file_not_contains "$STUB_LOG" "mise use"
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "mise use --global node@lts"
assert_file_not_contains "$STUB_LOG" "go@latest"
# lib/common.sh brings back the real confirm
load_script lib/common.sh
export PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
rm "$GLOBALS_FILE"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "mise use --global go@latest"
assert_file_not_contains "$STUB_LOG" "node@lts"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    mise's global go: not set; the repo's is latest"
unset MISE_NODE

touch "$GLOBALS_FILE" "$SANDBOX/global.toml"
MISE_GLOBAL_CONFIG_FILE="$SANDBOX/global.toml" EXPECTED_MISE_CONFIG="$SANDBOX/global.toml" assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "wrong file"
mv "$EXPECTED_MISE_CONFIG" "$SANDBOX/config.toml.aside"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "mise use --global node@lts go@latest"
assert_file_not_contains "$STUB_LOG" "mise config get"
mv "$SANDBOX/config.toml.aside" "$EXPECTED_MISE_CONFIG"
MISE_CONFIG_ERR=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "TOML parse error"
assert_contains "$RUN_OUTPUT" "Couldn't read mise's global config"
assert_file_not_contains "$STUB_LOG" "mise use"
MISE_CONFIG_ERR=1 run status
assert_contains "$RUN_OUTPUT" "unknown    mise's global node: couldn't read $EXPECTED_MISE_CONFIG"
rm "$GLOBALS_FILE"

for cmd in use install; do
    : > "$STUB_LOG"
    rm -rf "$HOME/.cargo"
    MISE_FAIL="$cmd" assert_exit 1 main
    assert_file_contains "$STUB_LOG" "rustup-init -y --no-modify-path"
done

: > "$STUB_LOG"
touch "$GLOBALS_FILE"
mkdir -p "$HOME/.cargo/bin"
cp "$RUST_STUB" "$HOME/.cargo/bin/rustup"
chmod +x "$HOME/.cargo/bin/rustup"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "rustup-init"
assert_file_not_contains "$STUB_LOG" "curl"

rm "$RUST_DEFAULT" "$RUST_HEALTHY"
assert_exit 3 main --status
assert_exit 0 main
assert_file_contains "$STUB_LOG" 'rustup default stable'
assert_exit 0 main --status
echo custom > "$RUST_DEFAULT"
assert_exit 0 main
assert_eq custom "$(cat "$RUST_DEFAULT")" "custom Rust default"
assert_file_not_contains "$STUB_LOG" 'toolchain install'
rm "$RUST_HEALTHY"
RUST_FAIL=1 assert_exit 1 main
assert_exit 0 main
assert_file_contains "$STUB_LOG" 'rustup toolchain install custom'

# mise install in $HOME installs every active config, ~/mise.toml and ~/.tool-versions included
MISE_LS_OUT="python  3.13 (missing)  ~/mise.toml  3.13" assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The tools mise's configs in ~ list installed"
assert_file_contains "$STUB_LOG" "mise ls --missing"
assert_file_not_contains "$STUB_LOG" "mise ls --missing --global"

rm "$HOME/.cargo/bin/rustup"
cp "$RUST_STUB" "$STUB_DIR/rustup"
assert_exit 1 rustup_installed
rm "$STUB_DIR/rustup"
test_done
