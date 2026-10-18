#!/bin/bash
set -euo pipefail

# Both runners take -h/--help, --status, --quick, --backup, and --no-backup anywhere among the step
# names, and fail with a usage line on an unknown flag. check_args reads --status and --quick
# wherever they are too.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

setup_sh="$REPO_DIR/setup.sh"
ai_setup_sh="$REPO_DIR/ai_tools/setup.sh"

# A status run, wherever its flags are: the vim step's report, and nothing installed
first=""
for args in "vim --status" "--backup --status vim --quick"; do
    # shellcheck disable=SC2086 # split into arguments
    assert_exit 3 "$BASH" "$setup_sh" $args
    assert_contains "$RUN_OUTPUT" "=== dotfiles status ===" "setup.sh $args"
    assert_contains "$RUN_OUTPUT" "missing    ~/.vimrc" "setup.sh $args"
    assert_not_contains "$RUN_OUTPUT" "=== dotfiles setup" "setup.sh $args"
    [ ! -e "$HOME/.vimrc" ] || fail "setup.sh $args installed ~/.vimrc"
    [ -n "$first" ] || first="$RUN_OUTPUT"
    assert_eq "$first" "$RUN_OUTPUT" "output of setup.sh $args"
done
assert_exit 0 "$BASH" "$ai_setup_sh" manual-steps --status --no-backup
assert_contains "$RUN_OUTPUT" "=== AI tools status ==="
assert_not_contains "$RUN_OUTPUT" "Unknown"
# A step that needs attention makes ai_tools/setup.sh --status exit 3, naming it
assert_exit 3 "$BASH" "$ai_setup_sh" --status skills
assert_contains "$RUN_OUTPUT" "Needs attention: skills."

# Help, wherever it is, prints the usage and runs nothing
assert_exit 0 "$BASH" "$setup_sh" vim --help
assert_contains "$RUN_OUTPUT" "Usage: bash setup.sh"
assert_not_contains "$RUN_OUTPUT" "==="
assert_exit 0 "$BASH" "$ai_setup_sh" --backup -h skills
assert_contains "$RUN_OUTPUT" "Usage: bash ai_tools/setup.sh"
[ ! -e "$HOME/.vimrc" ] || fail "help installed ~/.vimrc"

# An unknown flag fails with the usage, and runs nothing
assert_exit 2 "$BASH" "$setup_sh" --status vim -x
assert_contains "$RUN_OUTPUT" "Unknown option: -x"
assert_contains "$RUN_OUTPUT" "Usage: bash setup.sh"
assert_not_contains "$RUN_OUTPUT" "==="
assert_exit 2 "$BASH" "$ai_setup_sh" skills --foo
assert_contains "$RUN_OUTPUT" "Unknown option: --foo"
assert_contains "$RUN_OUTPUT" "Usage: bash ai_tools/setup.sh"
[ ! -e "$HOME/.vimrc" ] || fail "an unknown flag installed ~/.vimrc"

# --quick only shortens a status report, so without --status it fails with the usage, and runs
# nothing
assert_exit 2 "$BASH" "$setup_sh" --quick --backup vim
assert_contains "$RUN_OUTPUT" "--quick only works with --status"
assert_contains "$RUN_OUTPUT" "Usage: bash setup.sh"
assert_not_contains "$RUN_OUTPUT" "==="
assert_exit 2 "$BASH" "$ai_setup_sh" skills --quick
assert_contains "$RUN_OUTPUT" "--quick only works with --status"
assert_contains "$RUN_OUTPUT" "Usage: bash ai_tools/setup.sh"
[ ! -e "$HOME/.vimrc" ] || fail "--quick without --status installed ~/.vimrc"

# A setup run with a flag after the step names installs them
assert_exit 0 "$BASH" "$setup_sh" vim --no-backup
assert_contains "$RUN_OUTPUT" "=== dotfiles setup ==="
assert_file_contains "$HOME/.vimrc" "$(head -1 "$REPO_DIR/vim/vimrc")"

# check_args: --status anywhere stops Homebrew's auto-update, and --quick sets
# DOTFILES_STATUS_QUICK, for the runner and the steps it starts
read_flags() {
    env -u HOMEBREW_NO_AUTO_UPDATE -u DOTFILES_STATUS_QUICK "$BASH" -c '
        . "$0/lib/common.sh"
        check_args : words "$@"
        echo "${HOMEBREW_NO_AUTO_UPDATE:-unset} ${DOTFILES_STATUS_QUICK:-unset}"' "$REPO_DIR" "$@"
}
run read_flags vim --status
assert_eq "1 unset" "$RUN_OUTPUT" "variables after vim --status"
run read_flags --backup --status --quick
assert_eq "1 1" "$RUN_OUTPUT" "variables after --backup --status --quick"
run read_flags vim
assert_eq "unset unset" "$RUN_OUTPUT" "variables after vim"

# A step run directly takes --status anywhere among its flags, and then only reports
stub gh
assert_exit 3 "$BASH" "$REPO_DIR/git/install.sh" --no-backup --status --quick
assert_contains "$RUN_OUTPUT" "missing    ~/.config/git/config"
[ ! -e "$HOME/.config/git/config" ] || fail "git/install.sh --status installed the git config"
assert_exit 0 "$BASH" "$REPO_DIR/manual-steps.sh" --status --no-backup
assert_eq "" "$RUN_OUTPUT" "manual-steps.sh --status"

# A step run directly prints its usage for -h or --help and fails on an unknown flag or any word,
# changing nothing either way
export HOME="$SANDBOX/home-help"
mkdir -p "$HOME"
step=git/install.sh
assert_exit 0 "$BASH" "$REPO_DIR/$step" -h
assert_eq "Usage: bash $step [--status [--quick]] [--backup | --no-backup]" "$RUN_OUTPUT" "$step -h"
assert_exit 2 "$BASH" "$REPO_DIR/$step" --status --stauts
assert_contains "$RUN_OUTPUT" "Unknown option: --stauts"
assert_contains "$RUN_OUTPUT" "Usage: bash $step"
# --quick needs --status
assert_exit 2 "$BASH" "$REPO_DIR/$step" --quick
assert_contains "$RUN_OUTPUT" "--quick only works with --status"
# A word without a dash, such as status for --status, doesn't run the step either
assert_exit 2 "$BASH" "$REPO_DIR/$step" status
assert_contains "$RUN_OUTPUT" "Unknown argument: status"
assert_contains "$RUN_OUTPUT" "Usage: bash $step"
assert_eq "" "$(find "$HOME" -mindepth 1)" "files a step wrote for -h, --stauts, or status"

# The runners start each step with the bash running them, not whichever bash is first on PATH,
# such as Homebrew's
stub bash 'exit 99'
assert_exit 0 "$BASH" "$setup_sh" vim
assert_exit 3 "$BASH" "$setup_sh" --status zed
assert_file_not_contains "$STUB_LOG" "bash "
rm -f "$STUB_DIR/bash"

# An exported CDPATH with dirs named like the scripts' relative dirs doesn't change the paths
# they source: cd would go to those, and print the path, doubling it
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
