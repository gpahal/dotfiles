#!/bin/bash
set -euo pipefail

# The config steps run through setup.sh twice in a sandbox: the second run changes nothing, and
# --status then reports everything set up apart from the GitHub login and the settings that depend
# on it. Stubs stand in for what would touch the real machine: gh, the account's login
# shell (dscl, getent), launchctl, systemctl, chsh, brew, and lib.sh's sudo. tpm's clone from GitHub
# gets a fake local tpm.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

STEPS=(git lazygit ssh zsh vim tmux zed editorconfig)
command -v git &>/dev/null || skip "git isn't installed"
# The tmux step needs tmux installed, though the fake tpm below never runs it
if ! command -v tmux &>/dev/null; then
    skip_rest "the tmux step: tmux isn't installed"
    STEPS=(git lazygit ssh zsh vim zed editorconfig)
fi

# A brew on PATH stops lib/common.sh from putting Homebrew's directories before the stubs
stub brew 'exit 1'
# Not logged in to GitHub, so the git step defers login without a terminal
stub gh 'exit 1'
# The login shell is already zsh, so the zsh step doesn't ask to run chsh
stub dscl 'case "$*" in *UserShell*) echo "UserShell: /bin/zsh" ;; *) exit 1 ;; esac'
stub getent 'echo "$2:x:1000:1000::$HOME:/usr/bin/zsh"'
stub chsh 'exit 1'
# The ssh step's LaunchAgent counts as loaded: a temp HOME mustn't load it into your session
stub launchctl '[ "$1" == print ]'
# On Ubuntu, continuum's unit that starts tmux at boot counts as enabled: tests/test-tmux-boot.sh
# covers enabling it
stub systemctl '[ "$*" == "--user is-enabled --quiet tmux.service" ]'

# A local tpm whose install_plugins makes a directory for each plugin the installed tmux.conf
# lists, in place of cloning them from GitHub
TPM_REPO="$SANDBOX/tpm"
mkdir -p "$TPM_REPO/bin"
cat > "$TPM_REPO/bin/install_plugins" << 'EOF'
#!/bin/bash
printf '%s\n' "install_plugins" >> "$STUB_LOG"
sed -n "s/^set -g @plugin '\(.*\)'/\1/p" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" |
    while IFS= read -r plugin; do
        mkdir -p "$HOME/.tmux/plugins/${plugin##*/}"
    done
EOF
chmod +x "$TPM_REPO/bin/install_plugins"
git -C "$TPM_REPO" -c init.defaultBranch=main init -q
git -C "$TPM_REPO" add -A
git -C "$TPM_REPO" -c user.name=test -c user.email=test@example.com commit -qm tpm
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$TPM_REPO.insteadOf"
export GIT_CONFIG_VALUE_0=https://github.com/tmux-plugins/tpm

assert_exit 0 bash "$REPO_DIR/setup.sh" "${STEPS[@]}"
assert_contains "$RUN_OUTPUT" "Copied"
# Only macOS gets the keychain's SSH block
[ "$(uname -s)" != Darwin ] || assert_contains "$RUN_OUTPUT" "Added a Host * block"

# The second run copies and adds nothing
assert_exit 0 bash "$REPO_DIR/setup.sh" "${STEPS[@]}"
changes="$(printf '%s\n' "$RUN_OUTPUT" | grep -E 'Copied|Added' || true)"
assert_eq "" "$changes" "the second run's Copied and Added lines"

if [[ " ${STEPS[*]} " == *" tmux "* ]]; then
    assert_eq 1 "$(grep -c '^install_plugins$' "$STUB_LOG")" "tpm plugin installs"
fi
for cmd in brew chsh sudo "launchctl bootstrap"; do
    assert_file_not_contains "$STUB_LOG" "$cmd"
done

# Every status item is ok, skipped, or unverified, apart from the GitHub login and the credential
# helper, which gh sets up after you log in, and on Ubuntu the HTTPS rewrite, which needs the
# helper. That's why status exits 3.
assert_exit 3 bash "$REPO_DIR/setup.sh" --status "${STEPS[@]}"
items="$(printf '%s\n' "$RUN_OUTPUT" | grep -E '^  [a-z]+ ' | grep -vE '^  (ok|skipped|unverified) ' || true)"
expected="  missing    Logged in to GitHub with gh
  missing    git uses gh for GitHub credentials"
if [ "$(uname -s)" != Darwin ]; then
    expected+="
  missing    GitHub SSH remotes go over HTTPS, through gh's credential helper (a re-run after gh auth login and gh auth setup-git adds it)"
fi
assert_eq "$expected" "$items" "status items that need attention"

# Logged in, the git step sets up gh's credential helper once, and status is all set. Like gh,
# the stub clears the helpers before it with an empty one, such as macOS's osxkeychain.
stub gh 'case "$1 $2" in
    "auth status" | "auth token") exit 0 ;;
    "auth setup-git")
        git config --global --add credential.https://github.com.helper ""
        git config --global --add credential.https://github.com.helper "!gh auth git-credential"
        ;;
    *) exit 1 ;;
esac'
assert_exit 0 bash "$REPO_DIR/setup.sh" git
assert_contains "$RUN_OUTPUT" "Set git to use gh for GitHub credentials"
assert_exit 0 bash "$REPO_DIR/setup.sh" git
assert_contains "$RUN_OUTPUT" "git already uses gh for GitHub credentials"
assert_exit 0 bash "$REPO_DIR/setup.sh" --status "${STEPS[@]}"
test_done
