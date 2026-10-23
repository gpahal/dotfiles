#!/bin/bash
set -euo pipefail

# The runners, through runner_main, take -h/--help, --status, --for-alerts, --backup, and --no-backup
# anywhere among the step names, and fail with a usage line on an unknown flag or step.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

setup_sh="$REPO_DIR/setup.sh"

first=""
for args in "vim --status" "--backup --status vim --for-alerts"; do
    # shellcheck disable=SC2086 # split into arguments
    assert_exit 3 "$BASH" "$setup_sh" $args
    assert_contains "$RUN_OUTPUT" "=== dotfiles status ===" "setup.sh $args"
    assert_contains "$RUN_OUTPUT" "missing    ~/.vimrc" "setup.sh $args"
    assert_not_contains "$RUN_OUTPUT" "=== dotfiles setup" "setup.sh $args"
    [ ! -e "$HOME/.vimrc" ] || fail "setup.sh $args installed ~/.vimrc"
    [ -n "$first" ] || first="$RUN_OUTPUT"
    assert_eq "$first" "$RUN_OUTPUT" "output of setup.sh $args"
done

assert_exit 0 "$BASH" "$setup_sh" vim --help
assert_contains "$RUN_OUTPUT" "Usage: bash setup.sh"
assert_not_contains "$RUN_OUTPUT" "==="
header="$(load_script lib/common.sh && step_header_line "$REPO_DIR/vim/install.sh")"
[ -n "$header" ] || fail "vim/install.sh has no header line"
assert_contains "$RUN_OUTPUT" "  vim             $header"
[ ! -e "$HOME/.vimrc" ] || fail "help installed ~/.vimrc"

assert_exit 2 "$BASH" "$setup_sh" --status vim -x
assert_contains "$RUN_OUTPUT" "Unknown option: -x"
assert_contains "$RUN_OUTPUT" "Usage: bash setup.sh"
assert_not_contains "$RUN_OUTPUT" "==="
[ ! -e "$HOME/.vimrc" ] || fail "an unknown flag installed ~/.vimrc"

# A name with a space or slash is unknown, even when it matches adjacent steps
for name in "git lazygit" "git/" "../setup"; do
    assert_exit 1 "$BASH" "$setup_sh" --status "$name"
    assert_contains "$RUN_OUTPUT" "Unknown step: $name." "setup.sh --status '$name'"
    assert_not_contains "$RUN_OUTPUT" "git config" "setup.sh --status '$name'"
done

assert_exit 2 "$BASH" "$setup_sh" --for-alerts --backup vim
assert_contains "$RUN_OUTPUT" "--for-alerts only works with --status"
assert_contains "$RUN_OUTPUT" "Usage: bash setup.sh"
assert_not_contains "$RUN_OUTPUT" "==="
[ ! -e "$HOME/.vimrc" ] || fail "--for-alerts without --status installed ~/.vimrc"

# A step given a word, as `install.sh status` for --status, fails rather than applying
export HOME="$SANDBOX/home-help"
mkdir -p "$HOME"
assert_exit 2 "$BASH" "$REPO_DIR/git/install.sh" status
assert_eq "" "$(find "$HOME" -mindepth 1)" "files git/install.sh status wrote"

# The runners use their own bash, not the first on PATH, such as Homebrew's
stub bash 'exit 99'
assert_exit 0 "$BASH" "$setup_sh" vim
assert_exit 3 "$BASH" "$setup_sh" --status zed
assert_file_not_contains "$STUB_LOG" "bash "
rm -f "$STUB_DIR/bash"

# cd prints the path when CDPATH matches, which would double a sourced path
export HOME="$SANDBOX/home-cdpath"
mkdir -p "$HOME" "$SANDBOX/cdpath/vim"
cd "$REPO_DIR"
for script in setup.sh vim/install.sh; do
    assert_exit 0 env CDPATH="$SANDBOX/cdpath" "$BASH" "$script" --help
    assert_contains "$RUN_OUTPUT" "Usage: bash $script" "$script --help with CDPATH"
done
assert_exit 3 env CDPATH="$SANDBOX/cdpath" "$BASH" vim/install.sh --status
assert_contains "$RUN_OUTPUT" "missing    ~/.vimrc" "vim/install.sh --status with CDPATH"
cd "$SANDBOX"
test_done
