#!/bin/bash
set -euo pipefail

# --status --quick (DOTFILES_STATUS_QUICK=1) skips the slowest checks. This covers two of them: the
# homebrew step reports the Brewfile as unverified instead of running brew bundle check, and the
# Ubuntu t3-code step checks once whether the service is active instead of watching it for up to
# 10 s, and doesn't run t3 browser setup.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# homebrew, on Ubuntu with Homebrew and its casks installed
load_script homebrew/install.sh
as_os ubuntu
replace_fn missing_ubuntu_commands :
replace_fn locale_installed true
# brew lists the Ubuntu casks as installed
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
# unverified doesn't need attention
assert_exit 0 status

# t3-code on Ubuntu, with the service installed and active
unset DOTFILES_STATUS_QUICK
load_script ai_tools/t3-code/install.sh
as_os ubuntu
replace_fn apt_installed false
mkdir -p "$(dirname "$T3_CODE_SERVICE_UNIT")"
touch "$T3_CODE_SERVICE_UNIT"
stub systemctl 'case "$2" in is-active | is-enabled) exit 0 ;; show) echo 4242 ;; esac'
stub sleep
# No t3 serve started by hand, and the server listens on loopback
stub pgrep 'exit 1'
stub ss 'echo "LISTEN 0 511 127.0.0.1:3773 0.0.0.0:*"'
# The t3 CLI, whose browser is set up
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
assert_file_not_contains "$STUB_LOG" "systemctl --user show"
assert_file_not_contains "$STUB_LOG" "sleep"
assert_file_not_contains "$STUB_LOG" "t3 browser setup"
assert_contains "$RUN_OUTPUT" "unverified T3 Code's browser sandbox: skipped by --quick"

# An inactive service is still reported as not running
stub systemctl 'case "$2" in is-active) exit 3 ;; is-enabled) exit 0 ;; show) echo 0 ;; esac'
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service running"
test_done
