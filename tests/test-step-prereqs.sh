#!/bin/bash
set -euo pipefail

# A step missing a prerequisite fails before it changes anything, and status reports the check
# unknown. chrome without curl is in test-chrome.sh.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox

# Subshell, so the rest of the test still has the command
without() {
    local name="$1"
    shift
    (
        hide "$name"
        "$@"
    )
}

check_untouched() {
    assert_file_not_contains "$STUB_LOG" "install"
    assert_file_not_contains "$STUB_LOG" "sudo"
    assert_eq "" "$(/bin/ls -A "$HOME")" "files in \$HOME after $1 failed up front"
}

claude_code() {
    load_script ai_tools/claude-code/install.sh
    replace_fn install_claude_code 'echo "install claude" >> "$STUB_LOG"'
    replace_fn claude_code_have_git_wt true
    main
}
# Not installed yet, so the step would fetch Anthropic's script
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
# Without Tailscale the step downloads its apt key
ubuntu_no_tailscale() {
    without tailscale ubuntu_step
}
t3_code_macos() {
    load_script ai_tools/t3-code/install.sh
    as_os macos
    main
}
# Without the t3 CLI the step downloads it
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

# The codex step checks for yq first
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
    # mise is there, so the step must stop before running it
    [ "$step" != runtimes_step ] || assert_file_not_contains "$STUB_LOG" "mise"
done

# The zsh step without the login zsh it needs
for os in macos ubuntu; do
    rm -rf "$HOME"
    mkdir -p "$HOME"
    : > "$STUB_LOG"
    load_script zsh/install.sh
    as_os "$os"
    replace_fn login_zsh_path 'return 1'
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "zsh is missing" "the zsh step's output on $os"
    check_untouched "zsh on $os"
done

# Status reports a check whose prerequisite is missing as unknown, not missing or a crash
chrome_status_without_gpg() {
    stub_apt_config
    load_script chrome/install.sh
    as_os ubuntu
    stub dpkg-query 'echo "install ok installed"'
    stub snap 'exit 1'
    hide gpg
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "unknown    Google's apt key ($GOOGLE_KEYRING) is the one the step pins: gpg isn't installed"
    assert_not_contains "$RUN_OUTPUT" "command not found"
    assert_contains "$RUN_OUTPUT" "missing    Firefox removed, since Chrome replaces it"
}
codex_status_without_brew() {
    load_script ai_tools/codex/install.sh
    as_os ubuntu
    hide brew codex
    stub bwrap
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "unknown    codex: brew isn't installed"
    assert_not_contains "$RUN_OUTPUT" "missing    codex (cask)"
}
subtest chrome_status_without_gpg
subtest codex_status_without_brew
test_done
