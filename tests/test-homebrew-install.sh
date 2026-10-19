#!/bin/bash
set -euo pipefail

# Without a terminal, the homebrew step installs Homebrew when sudo is cached or the prefix
# already exists, and otherwise stops before the installer, on both OSes. missing_ubuntu_commands
# checks for locale-gen and fc-cache along with the rest. A cask install that brew's Ctrl-C stops
# ends the step.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script homebrew/install.sh
hide brew
replace_fn run_installer 'echo "run_installer $*" >> "$STUB_LOG"'
replace_fn load_brew
PREFIX="$SANDBOX/homebrew"
replace_fn homebrew_prefix 'echo "$PREFIX"'

for os in ubuntu macos; do
    as_os "$os"

    # No terminal, no prefix, and sudo would ask for a password: stop before the installer
    : > "$STUB_LOG"
    stub sudo 'exit 1'
    assert_exit 1 install_homebrew
    assert_contains "$RUN_OUTPUT" "Installing Homebrew needs sudo" "$os, sudo not cached"
    assert_file_not_contains "$STUB_LOG" "run_installer"

    # Cached sudo: the installer runs, and uses sudo -n itself
    : > "$STUB_LOG"
    stub sudo 'exit 0'
    assert_exit 0 install_homebrew
    assert_file_contains "$STUB_LOG" "run_installer bash https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

    # The prefix exists, so the installer needs no sudo
    : > "$STUB_LOG"
    stub sudo 'exit 1'
    mkdir -p "$PREFIX"
    assert_exit 0 install_homebrew
    assert_file_contains "$STUB_LOG" "run_installer bash"
    rmdir "$PREFIX"
done

# brew catches Ctrl-C and exits 130, so install_cask exits with it, rather than returning a failure
# that a caller's `|| result=1` would turn into 1. Any other failure returns, so the rest still
# install, including other codes above 128 such as 137, 141 from SIGPIPE, or 255.
load_script homebrew/install.sh
as_os ubuntu
replace_fn cask_state "printf 'missing\t\n'"
# shellcheck disable=SC2034 # os_casks reads it
UBUNTU_CASKS=(foo bar)
stub fc-cache
direct() {
    install_cask foo "" || echo "returned $?"
}
for code in 130 143 129 1 137 141 255; do
    stub brew "exit $code"
    : > "$STUB_LOG"
    if ! interrupted_status "$code"; then
        assert_exit 1 install_casks
        assert_contains "$RUN_OUTPUT" "These casks failed to install: foo bar."
    else
        assert_exit "$code" install_casks
        assert_not_contains "$RUN_OUTPUT" "failed to install"
        assert_file_not_contains "$STUB_LOG" "install --cask bar"
        assert_exit "$code" direct
        assert_not_contains "$RUN_OUTPUT" "returned"
    fi
done

# A cask that runs an installer names no app in brew's metadata, so cask_state takes its app from
# CASK_PKG_APPS, on macOS. Without it, an app installed outside brew would count as missing.
load_script homebrew/install.sh
as_os macos
stub brew 'exit 1'
for entry in "elgato-stream-deck=/Applications/Elgato Stream Deck.app" "tailscale-app=/Applications/Tailscale.app"; do
    IFS=$'\t' read -r _ app <<< "$(cask_state "${entry%%=*}")"
    assert_eq "${entry#*=}" "$app" "the app cask_state finds for ${entry%%=*}"
done

# shellcheck disable=SC2034 # missing_ubuntu_commands reads it
UBUNTU_COMMANDS=(sh)
expected=""
for cmd in locale-gen fc-cache; do
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v "$cmd" &>/dev/null ||
        expected="$expected $cmd"
done
assert_eq "$expected" "$(missing_ubuntu_commands)" "missing commands with only sh, locale-gen, and fc-cache to check"
test_done
