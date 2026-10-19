#!/bin/bash
set -euo pipefail

# A step missing a command it needs fails before it changes anything. chrome without curl is in
# test-chrome.sh.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox

# without <cmd> <command...>: run a command with <cmd> hidden, in a subshell, so the rest of the
# test still has it
without() {
    local name="$1"
    shift
    (
        hide "$name"
        "$@"
    )
}

# check_untouched <step>: fail when the step logged an install or a sudo, or wrote to $HOME
check_untouched() {
    assert_file_not_contains "$STUB_LOG" "install"
    assert_file_not_contains "$STUB_LOG" "sudo"
    assert_eq "" "$(/bin/ls -A "$HOME")" "files in \$HOME after $1 failed up front"
}

# Each loads a step, replaces what decides its path (and any installer, logging it), and runs main
claude_code() {
    load_script ai_tools/claude-code/install.sh
    replace_fn install_claude_code 'echo "install claude" >> "$STUB_LOG"'
    replace_fn claude_code_have_git_wt true
    main
}
# Claude Code not yet installed, which the step would install with Anthropic's script
claude_code_fresh() {
    load_script ai_tools/claude-code/install.sh
    replace_fn claude_code_path 'return 1'
    replace_fn claude_code_have_git_wt true
    main
}
claude_desktop() {
    load_script ai_tools/claude-desktop/install.sh
    as_os macos
    replace_fn install_cask 'echo "install $1" >> "$STUB_LOG"'
    main
}
codex() {
    load_script ai_tools/codex/install.sh
    as_os macos
    replace_fn install_cask 'echo "install $1" >> "$STUB_LOG"'
    replace_fn codex_cask_path :
    main
}
tmux_step() {
    load_script tmux/install.sh
    main
}
git_step() {
    load_script git/install.sh
    as_os macos
    main
}
ubuntu_step() {
    load_script ubuntu/install.sh
    ubuntu_sandbox_paths
    as_os ubuntu
    main
}
docker_step() {
    load_script docker/install.sh
    as_os ubuntu
    main
}
# The ubuntu step without Tailscale, whose apt key it would download to install it
ubuntu_no_tailscale() {
    without tailscale ubuntu_step
}
t3_code_macos() {
    load_script ai_tools/t3-code/install.sh
    as_os macos
    main
}
# T3 Code on Ubuntu without the t3 CLI, which it would download
t3_code_ubuntu() {
    load_script ai_tools/t3-code/install.sh
    as_os ubuntu
    replace_fn apt_installed false
    main
}
runtimes_step() {
    load_script runtimes/install.sh
    stub mise
    replace_fn rustup_installed false
    main
}
runtimes_no_mise() {
    load_script runtimes/install.sh
    replace_fn rustup_installed false
    main
}

# The codex step checks for yq first, so a stub stands in for it where it isn't installed
command -v yq &>/dev/null || stub yq
for check in "jq claude_code" "curl claude_code_fresh" "jq claude_desktop" "yq codex" "tmux tmux_step" \
    "git tmux_step" "gh git_step" "jq ubuntu_step" "curl ubuntu_no_tailscale" "jq docker_step" \
    "gpg ubuntu_no_tailscale" "gpg docker_step" "brew t3_code_macos" "curl t3_code_ubuntu" \
    "mise runtimes_no_mise" "curl runtimes_step"; do
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
        as_os ubuntu
    fi
    replace_fn login_zsh_path 'return 1'
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "zsh is missing" "the zsh step's output on $os"
    check_untouched "zsh on $os"
done
test_done
