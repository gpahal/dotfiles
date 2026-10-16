#!/bin/bash
# The steps' functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# A step missing a command it needs fails before it changes anything: claude-code and claude-desktop
# without jq, claude-code without curl when Claude Code is missing, codex without yq, tmux without
# tmux or git, git without gh, ubuntu and docker without jq, ubuntu without curl when Tailscale is
# missing, t3-code without brew on macOS and without curl on Ubuntu when it would download the app
# or the CLI, runtimes without mise, and without curl when rustup is missing, and zsh without its
# login zsh. chrome without curl is in test-chrome.sh.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# without <cmd> <command...>: run a command with a PATH that lacks <cmd>, unlike hide, which drops
# it for the rest of the test. Each PATH dir that has <cmd> is swapped for a dir of links to its
# other commands, so only the dirs with it cost links. load_script puts $STUB_DIR first again, so
# its stub or sentinel moves aside meanwhile. Without brew, DOTFILES_NO_LOAD_BREW stops
# lib/common.sh from putting Homebrew's dirs back on PATH.
without() {
    local name="$1" entry dirs path="" links status=0
    shift
    [ ! -e "$STUB_DIR/$name" ] || mv "$STUB_DIR/$name" "$SANDBOX/aside-$name"
    IFS=: read -ra dirs <<< "$PATH"
    for entry in ${dirs[@]+"${dirs[@]}"}; do
        if [ -e "$entry/$name" ]; then
            links="$SANDBOX/without-$name${entry//\//_}"
            if [ ! -d "$links" ]; then
                mkdir -p "$links"
                ln -s "$entry"/* "$links"/ 2> /dev/null || true
                rm -f "$links/$name"
            fi
            entry="$links"
        fi
        path="${path:+$path:}$entry"
    done
    if [ "$name" == brew ]; then
        PATH="$path" DOTFILES_NO_LOAD_BREW=1 "$@" || status=$?
    else
        PATH="$path" "$@" || status=$?
    fi
    [ ! -e "$SANDBOX/aside-$name" ] || mv "$SANDBOX/aside-$name" "$STUB_DIR/$name"
    return "$status"
}

# check_untouched <step>: fail when the step logged an install or wrote to $HOME
check_untouched() {
    assert_file_not_contains "$STUB_LOG" "install"
    assert_eq "" "$(/bin/ls -A "$HOME")" "files in \$HOME after $1 failed up front"
}

# Each loads a step, replaces what decides its path (and any installer, logging it), and runs main
claude_code() {
    load_script ai_tools/claude-code/install.sh
    install_claude_code() { echo "install claude" >> "$STUB_LOG"; }
    claude_code_have_git_wt() { true; }
    main
}
# Claude Code not yet installed, which the step would install with Anthropic's script
claude_code_fresh() {
    load_script ai_tools/claude-code/install.sh
    claude_code_path() { return 1; }
    claude_code_have_git_wt() { true; }
    main
}
claude_desktop() {
    load_script ai_tools/claude-desktop/install.sh
    is_macos() { true; }
    install_cask() { echo "install $1" >> "$STUB_LOG"; }
    main
}
codex() {
    load_script ai_tools/codex/install.sh
    is_macos() { true; }
    is_ubuntu() { false; }
    install_cask() { echo "install $1" >> "$STUB_LOG"; }
    codex_cask_path() { :; }
    main
}
tmux_step() {
    load_script tmux/install.sh
    main
}
git_step() {
    load_script git/install.sh
    is_macos() { true; }
    is_ubuntu() { false; }
    main
}
ubuntu_step() {
    load_script ubuntu/install.sh
    is_ubuntu() { true; }
    main
}
docker_step() {
    load_script docker/install.sh
    is_macos() { false; }
    is_ubuntu() { true; }
    main
}
# The ubuntu step without Tailscale, whose apt key it would download to install it
ubuntu_no_tailscale() {
    without tailscale ubuntu_step
}
t3_code_macos() {
    load_script ai_tools/t3-code/install.sh
    is_macos() { true; }
    is_ubuntu() { false; }
    main
}
# T3 Code on Ubuntu without the desktop app or the t3 CLI, which it would download
t3_code_ubuntu() {
    load_script ai_tools/t3-code/install.sh
    is_macos() { false; }
    is_ubuntu() { true; }
    apt_installed() { false; }
    main
}
runtimes_step() {
    load_script runtimes/install.sh
    stub mise
    rustup_installed() { false; }
    main
}
runtimes_no_mise() {
    load_script runtimes/install.sh
    rustup_installed() { false; }
    main
}

# The codex step checks for yq first, so a stub stands in for it where it isn't installed
command -v yq &>/dev/null || stub yq
for check in "jq claude_code" "curl claude_code_fresh" "jq claude_desktop" "yq codex" "tmux tmux_step" \
    "git tmux_step" "gh git_step" "jq ubuntu_step" "curl ubuntu_no_tailscale" "jq docker_step" \
    "brew t3_code_macos" "curl t3_code_ubuntu" "mise runtimes_no_mise" "curl runtimes_step"; do
    cmd="${check% *}"
    step="${check#* }"
    rm -rf "$HOME"
    mkdir -p "$HOME"
    : > "$STUB_LOG"
    assert_exit 1 without "$cmd" "$step"
    assert_contains "$RUN_OUTPUT" "$cmd"
    check_untouched "$step without $cmd"
done
assert_file_not_contains "$STUB_LOG" "mise"

# The zsh step without the zsh it would make the login shell, /usr/bin/zsh on Ubuntu, fails before
# it copies the config or edits a startup file
for os in macos ubuntu; do
    rm -rf "$HOME"
    mkdir -p "$HOME"
    load_script zsh/install.sh
    if [ "$os" == ubuntu ]; then
        is_macos() { false; }
        is_ubuntu() { true; }
    fi
    login_zsh_path() { return 1; }
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "zsh is missing" "the zsh step's output on $os"
    check_untouched "zsh on $os"
done
test_done
