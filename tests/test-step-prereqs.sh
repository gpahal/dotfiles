#!/bin/bash

# A step missing a prerequisite fails before it changes anything, and status reports the check
# unknown. chrome without curl is in test-chrome.sh, and homebrew without mas, which fails only
# after the Brewfile, in test-homebrew.sh.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

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
    main "$@"
}
# Not installed yet, so the step would fetch Anthropic's script
claude_code_fresh() {
    load_script ai_tools/claude-code/install.sh
    replace_fn claude_code_path 'return 1'
    replace_fn claude_code_have_git_wt true
    main "$@"
}
claude_desktop() {
    load_script ai_tools/claude-desktop/install.sh
    as_os macos
    replace_fn install_cask 'echo "install $1" >> "$STUB_LOG"'
    main "$@"
}
codex() {
    load_script ai_tools/codex/install.sh
    as_os macos
    replace_fn install_cask 'echo "install $1" >> "$STUB_LOG"'
    replace_fn codex_cask_path :
    main "$@"
}
tmux_step() {
    load_script tmux/install.sh
    main "$@"
}
git_step() {
    load_script git/install.sh
    as_os macos
    main "$@"
}
ubuntu_step() {
    load_script ubuntu/install.sh
    ubuntu_sandbox_paths
    as_os ubuntu
    main "$@"
}
docker_step() {
    load_script docker/install.sh
    as_os ubuntu
    main "$@"
}
# Without Tailscale the step downloads its apt key
ubuntu_no_tailscale() {
    without tailscale ubuntu_step
}
t3_code_macos() {
    load_script ai_tools/t3-code/install.sh
    as_os macos
    main "$@"
}
# Without the t3 CLI the step downloads it
t3_code_ubuntu() {
    load_script ai_tools/t3-code/install.sh
    as_os ubuntu
    replace_fn apt_installed false
    main "$@"
}
runtimes_step() {
    load_script runtimes/install.sh
    stub mise
    replace_fn rustup_installed false
    main "$@"
}
runtimes_no_mise() {
    load_script runtimes/install.sh
    replace_fn rustup_installed false
    main "$@"
}

ghostty_ubuntu() {
    load_script ghostty/install.sh
    as_os ubuntu
    main "$@"
}
logitech_step() {
    load_script logitech/install.sh
    sandbox_paths logitech/install.sh
    as_os ubuntu
    stub dpkg-query 'exit 1'
    stub_http_status
    main "$@"
}
gnome_step() {
    load_script gnome/install.sh
    as_os ubuntu
    stub gnome-shell 'echo "GNOME Shell 50.1"'
    main "$@"
}

# The codex step checks for yq first
command -v yq &>/dev/null || stub yq
# <command> <step>[|<the status line it reports>]
for check in "jq claude_code" "curl claude_code_fresh" "jq claude_desktop" "yq codex" "tmux tmux_step" \
    "git tmux_step" "gh git_step" "jq ubuntu_step" "curl ubuntu_no_tailscale" "jq docker_step" \
    "curl docker_step" "gpg ubuntu_no_tailscale" "gpg docker_step" "brew t3_code_macos" \
    "curl t3_code_ubuntu" "mise runtimes_no_mise" "curl runtimes_step" \
    "snap ghostty_ubuntu|unknown    Ghostty snap" "gpg logitech_step" \
    "gsettings gnome_step|unknown    GNOME settings: gsettings"; do
    line=""
    case "$check" in *"|"*) line="${check#*|}" check="${check%%|*}" ;; esac
    cmd="${check% *}"
    step="${check#* }"
    rm -rf "$HOME"
    mkdir -p "$HOME"
    assert_exit 1 without "$cmd" "$step"
    assert_contains "$RUN_OUTPUT" "$cmd"
    check_untouched "$step without $cmd"
    # mise is there, so the step must stop before running it
    [ "$step" != runtimes_step ] || assert_file_not_contains "$STUB_LOG" "mise"
    if [ -n "$line" ]; then
        assert_exit 3 without "$cmd" "$step" --status
        assert_contains "$RUN_OUTPUT" "$line"
    fi
done

# Stream Deck's Node comes from mise, not PATH, and this sandbox has none
stream_deck_ubuntu() {
    load_script stream-deck/install.sh
    sandbox_paths RAPL_DIR="$SANDBOX/powercap" HIDRAW_DIR="$SANDBOX/hidraw" stream-deck/install.sh 'stream-deck/lib/*.sh'
    as_os ubuntu
    stub pnpm
    stub gsettings
    main "$@"
}
rm -rf "$HOME"
mkdir -p "$HOME"
assert_exit 1 stream_deck_ubuntu
assert_contains "$RUN_OUTPUT" "Node LTS isn't at $HOME/.local/share/mise/installs/node/lts/bin/node. Run bash setup.sh runtimes first."
check_untouched "stream-deck without Node"

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
