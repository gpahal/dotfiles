#!/bin/bash
set -euo pipefail

# --status --quick skips brew bundle check, and t3-code's 10 s service watch and browser setup.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

load_script homebrew/install.sh
as_os ubuntu
replace_fn missing_ubuntu_commands :
replace_fn locale_installed true
stub brew "[ \"\$1 \$2\" != 'list --cask' ] || printf '%s\n' ${UBUNTU_CASKS[*]}"

assert_exit 0 status
assert_file_contains "$STUB_LOG" "brew bundle check"
assert_contains "$RUN_OUTPUT" "ok         Brewfile brew formulae"

: > "$STUB_LOG"
export DOTFILES_STATUS_QUICK=1
run status
assert_file_not_contains "$STUB_LOG" "brew bundle"
assert_contains "$RUN_OUTPUT" "unverified Brewfile brew formulae (skipped by --quick"
assert_not_contains "$RUN_OUTPUT" "ok         Brewfile"
assert_exit 0 status

unset DOTFILES_STATUS_QUICK
load_script ai_tools/t3-code/install.sh
as_os ubuntu
replace_fn apt_installed false
mkdir -p "$(dirname "$T3_CODE_SERVICE_UNIT")"
touch "$T3_CODE_SERVICE_UNIT"
stub systemctl 'case "$2" in is-active | is-enabled) exit 0 ;; show) echo 4242 ;; esac'
stub sleep
stub pgrep 'case "$1" in -P) echo 4243 ;; *) exit 1 ;; esac'
stub ss 'echo "LISTEN 0 511 127.0.0.1:3773 0.0.0.0:*"'
mkdir -p "$HOME/.local/bin"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "t3 $*" >> "$STUB_LOG"' > "$HOME/.local/bin/t3"
chmod +x "$HOME/.local/bin/t3"
: > "$STUB_LOG"
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code service running"
assert_file_contains "$STUB_LOG" "systemctl --user show -p MainPID"
assert_file_contains "$STUB_LOG" "t3 browser setup"

: > "$STUB_LOG"
export DOTFILES_STATUS_QUICK=1
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code service running"
assert_eq 1 "$(grep -c 'is-active' "$STUB_LOG")" "is-active checks with --quick"
assert_eq 1 "$(grep -c 'systemctl --user show -p MainPID' "$STUB_LOG")" "MainPID checks with --quick"
assert_file_not_contains "$STUB_LOG" "sleep"
assert_file_not_contains "$STUB_LOG" "t3 browser setup"
assert_contains "$RUN_OUTPUT" "unverified T3 Code's browser sandbox: skipped by --quick"

stub systemctl 'case "$2" in is-active) exit 3 ;; is-enabled) exit 0 ;; show) echo 0 ;; esac'
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service running"
test_done
