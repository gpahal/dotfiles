#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# Without a terminal, the homebrew step installs Homebrew when sudo is cached or the prefix
# already exists, and otherwise stops before the installer, on both OSes. Ubuntu's apt packages
# include locales, for the locale-gen the ubuntu step runs.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script homebrew/install.sh
hide brew
run_installer() { echo "run_installer $*" >> "$STUB_LOG"; }
load_brew() { :; }
PREFIX="$SANDBOX/homebrew"
homebrew_prefix() { echo "$PREFIX"; }

for os in ubuntu macos; do
    if [ "$os" == ubuntu ]; then
        is_ubuntu() { true; }
        is_macos() { false; }
    else
        is_ubuntu() { false; }
        is_macos() { true; }
    fi

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

# The prefix the installer creates on each OS
unset -f homebrew_prefix
load_script homebrew/install.sh
is_ubuntu() { true; }
assert_eq /home/linuxbrew/.linuxbrew "$(homebrew_prefix)" "Ubuntu prefix"
is_ubuntu() { false; }
uname() { echo arm64; }
assert_eq /opt/homebrew "$(homebrew_prefix)" "Apple Silicon prefix"
unset -f uname

# locales provides locale-gen, and fontconfig fc-cache, which refreshes the font cache after the
# Monaspace cask. missing_ubuntu_commands checks for both along with the rest.
assert_contains " $UBUNTU_PACKAGES " " locales "
assert_contains " $UBUNTU_PACKAGES " " fontconfig "
# shellcheck disable=SC2034 # missing_ubuntu_commands reads it
UBUNTU_COMMANDS=(sh)
expected=""
for cmd in locale-gen fc-cache; do
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v "$cmd" &>/dev/null ||
        expected="$expected $cmd"
done
assert_eq "$expected" "$(missing_ubuntu_commands)" "missing commands with only sh, locale-gen, and fc-cache to check"
test_done
