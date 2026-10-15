#!/bin/bash
set -euo pipefail

# scripts/upgrade.sh, which zsh's upgrade and upgrade-ai-tools functions run, runs each tool's
# update, in order, on each OS, with every tool stubbed: apt on Ubuntu only, the Brewfile's new
# formulae, casks added to the homebrew step, self-updating casks that aren't running, rustup from
# ~/.cargo/bin only, the plugin managers, Claude Code's own updater only for its native install,
# even with HOME reached through a symlink, Claude Code's plugins outside project, local, and
# managed scopes. A failed stage doesn't stop the ones after it, and upgrade names the failed ones at the end
# and fails, but an interrupted one stops upgrade. A cask whose metadata brew can't give is left
# alone. The plugin stages move the vim and tmux plugins only to the commits the repo pins.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"
command -v jq &>/dev/null || skip "jq isn't installed"
JQ="$(command -v jq)"

# The homebrew step's CASKS, and brew info --installed's JSON for the casks given, each with its
# app in $SANDBOX/apps
HOMEBREW_CASKS="$("$BASH" -c 'source "$1/homebrew/install.sh"; printf "%s\n" "${CASKS[@]}"' bash "$REPO_DIR")"
installed_json() {
    local cask sep=""
    printf '{"casks": ['
    for cask in "$@"; do
        mkdir -p "$SANDBOX/apps/$cask.app"
        printf '%s{"token": "%s", "artifacts": [{"app": ["x.app"], "target": "%s"}]}' "$sep" "$cask" "$SANDBOX/apps/$cask.app"
        sep=,
    done
    echo ']}'
}
# Every cask but rectangle, which was added to the homebrew step since setup ran
# shellcheck disable=SC2046 # one word per cask
installed_json $(grep -vx rectangle <<< "$HOMEBREW_CASKS") > "$SANDBOX/installed.json"

# brew lists zed and claude as outdated casks, Claude's app runs, the Brewfile has new formulae,
# and no other self-updating cask is installed, so upgrade skips AppCleaner, The Unarchiver, and
# Logi Options+. As Homebrew does, `brew outdated` exits 1 when it lists a cask it was given. A
# bare `brew upgrade` logs whether it leaves the casks that update themselves alone.
stub brew 'case "$*" in
    "info --json=v2 --installed --cask") cat "'"$SANDBOX"'/installed.json" ;;
    upgrade) [ -z "${HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS:-}" ] || echo "(not auto_updates casks)" >> "$STUB_LOG" ;;
    "list --cask zed" | "list --cask claude") ;;
    "list --cask"*) exit 1 ;;
    "outdated --cask --greedy --quiet "*) echo "${!#}"; exit 1 ;;
    "info --json=v2 --cask zed") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Zed.app\"]}, \"x\"]}]}" ;;
    "info --json=v2 --cask claude") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Claude.app\"]}]}]}" ;;
    "bundle check"*) exit 1 ;;
esac'
stub pgrep '[[ "$*" == *Claude* ]]'
stub sudo
ln -s "$JQ" "$STUB_DIR/jq"
for cmd in mas vim uv rustup t3 fc-cache; do
    stub "$cmd"
done
# rustup's installer puts it in ~/.cargo/bin, which isn't on PATH
mkdir -p "$HOME/.cargo/bin"
mv "$STUB_DIR/rustup" "$HOME/.cargo/bin/rustup"
# upgrade runs mise from ~, away from any project's mise.toml in the dir it was started in. After
# mise upgrade, it applies mise's hook-env, so npm, and upgrade-ai-tools after it, run the new
# Node. The hook-env stub puts $SANDBOX/new-node, whose npm logs as "new-node npm", first on PATH.
# shellcheck disable=SC2016 # expanded by the stub
stub mise '[ "$PWD" == "$HOME" ] || echo "mise ran in $PWD" >> "$STUB_LOG"
[ "$*" != "hook-env --force -s bash" ] || echo "export PATH='"$SANDBOX/new-node"':\$PATH"'
stub npm
mkdir -p "$SANDBOX/new-node"
# shellcheck disable=SC2016 # expanded by the script
printf '%s\n' '#!/bin/bash' 'echo "new-node npm $*" >> "$STUB_LOG"' > "$SANDBOX/new-node/npm"
chmod +x "$SANDBOX/new-node/npm"
stub claude '[ "$*" != "plugin list --json" ] || echo "[
    {\"id\": \"a@m\", \"scope\": \"user\"},
    {\"id\": \"b@m\", \"scope\": \"project\"},
    {\"id\": \"c@m\", \"scope\": \"local\"},
    {\"id\": \"d@m\", \"scope\": \"managed\"}
]"'
stub codex
mkdir -p "$HOME/.vim/autoload" "$SANDBOX/tmp"
touch "$HOME/.vimrc" "$HOME/.vim/autoload/plug.vim"
# The tmux plugins are at their pins, from local repos in place of GitHub
fake_tmux_plugins
"$BASH" -c 'source "$1/tmux/install.sh" && sync_tmux_plugins' bash "$REPO_DIR" > /dev/null
# uname -s names the OS upgrade_on runs as, so the homebrew step's is_macos agrees with OSTYPE.
# Unlike a stub, it doesn't log.
printf '%s\n' '#!/bin/bash' '[ "$1" != -s ] || exec cat "'"$SANDBOX"'/uname-s"' 'exec /usr/bin/uname "$@"' > "$STUB_DIR/uname"
chmod +x "$STUB_DIR/uname"
echo Darwin > "$SANDBOX/uname-s"

# Run upgrade as if on the given OS, with only the stubs and the system's base commands
# on PATH, printing what ran, with the repo shown as REPO. TMPDIR puts the temp files in the sandbox on either OS. DOTFILES_DIR points elsewhere, since upgrade finds the Brewfile
# from its own path.
upgrade_on() {
    : > "$STUB_LOG"
    case "$1" in
        darwin*) echo Darwin ;;
        *) echo Linux ;;
    esac > "$SANDBOX/uname-s"
    PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" DOTFILES_DIR="$SANDBOX/nowhere" TMPDIR="$SANDBOX/tmp" \
        "$BASH" -c 'source "$2/scripts/upgrade.sh"; OSTYPE=$1; upgrade' bash "$1" "$REPO_DIR" < /dev/null > "$SANDBOX/output" 2>&1 || {
        fail "upgrade failed on $1:"
        _show "$(cat "$SANDBOX/output")"
    }
    sed -e "s|$HOME|~|g" -e "s|$REPO_DIR/|REPO/|g" -e "/^$(basename "$JQ") /d" "$STUB_LOG"
}

# macOS. Claude Code is the native install, which updates itself.
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
mv "$STUB_DIR/claude" "$HOME/.local/share/claude/versions/2.0.0"
ln -s "$HOME/.local/share/claude/versions/2.0.0" "$HOME/.local/bin/claude"
assert_eq "brew update
brew upgrade
(not auto_updates casks)
brew bundle check --file=REPO/homebrew/Brewfile --no-upgrade
brew bundle install --file=REPO/homebrew/Brewfile --no-upgrade
brew info --json=v2 --installed --cask
brew info --json=v2 --cask rectangle
brew list --cask rectangle
brew info --json=v2 --cask rectangle
brew install --cask rectangle
brew cleanup
brew list --cask zed
brew outdated --cask --greedy --quiet zed
brew info --json=v2 --cask zed
pgrep -af ^/Applications/Zed[^/]*\\.app/Contents/MacOS/
brew upgrade --cask --greedy zed
brew list --cask appcleaner
brew list --cask the-unarchiver
brew list --cask logi-options+
mas upgrade
vim -Nes -u ~/.vimrc -i NONE -c PlugUpdate --sync -c qa
mise upgrade
mise hook-env --force -s bash
new-node npm update -g
uv tool upgrade --all
rustup update
claude update
brew list --cask claude
brew outdated --cask --greedy --quiet claude
brew info --json=v2 --cask claude
pgrep -af ^/Applications/Claude[^/]*\\.app/Contents/MacOS/
brew list --cask chatgpt
brew list --cask t3-code
brew list --cask codex
claude plugin marketplace update
claude plugin list --json
claude plugin update a@m --scope user
t3 update
codex plugin marketplace upgrade" "$(upgrade_on darwin25.0)" "commands upgrade runs on macOS"
assert_file_contains "$SANDBOX/output" "Claude is running; quit it and run upgrade-ai-tools again to update it."

# With HOME reached through a symlink, Claude Code still counts as the native install
ln -s "$HOME" "$SANDBOX/home-link"
: > "$STUB_LOG"
env HOME="$SANDBOX/home-link" PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade_ai_tools' bash "$REPO_DIR" \
    < /dev/null > "$SANDBOX/output" 2>&1 || true
assert_file_contains "$STUB_LOG" "claude update"

# A rustup elsewhere on PATH isn't the runtimes step's, so it's left alone
mv "$HOME/.cargo/bin/rustup" "$STUB_DIR/rustup"
assert_not_contains "$(upgrade_on darwin25.0)" "rustup" "commands upgrade runs with rustup only on PATH"
mv "$STUB_DIR/rustup" "$HOME/.cargo/bin/rustup"

# brew bundle check fails on a missing App Store app, which brew bundle install can't fix without
# an App Store sign-in, so upgrade has it skip the Brewfile's App Store apps by id. Here only those
# apps would fail the check, so bundle install doesn't run.
cp "$STUB_DIR/brew" "$SANDBOX/brew"
stub brew 'case "$*" in
    "bundle check"*) [ "${HOMEBREW_BUNDLE_MAS_SKIP:-}" == "937984704 1470584107 1295203466 " ] ;;
    "list --cask"*) exit 1 ;;
esac'
assert_not_contains "$(upgrade_on darwin25.0)" "bundle install" "commands upgrade runs with an App Store app missing"
assert_eq "" "$(ls -A "$SANDBOX/tmp")" "files upgrade leaves in TMPDIR"
cp "$SANDBOX/brew" "$STUB_DIR/brew"

# Without mas, upgrade skips the App Store and doesn't count it as failed
rm "$STUB_DIR/mas"
assert_not_contains "$(upgrade_on darwin25.0)" "mas" "commands upgrade runs on macOS without mas"
stub mas

# A cask with no app artifact, such as Logi Options+, which installs through an installer and quits
# its own app and agents first, upgrades with no running check, whatever app runs
cp "$STUB_DIR/brew" "$SANDBOX/brew"
stub brew 'case "$*" in
    "list --cask logi-options+") ;;
    "outdated --cask --greedy --quiet "*) echo "${!#}"; exit 1 ;;
    "info --json=v2 --cask logi-options+") echo "{\"casks\": [{\"artifacts\": [{\"installer\": [{\"manual\": \"x\"}]}, {\"uninstall\": []}, {\"zap\": []}]}]}" ;;
esac'
stub pgrep 'exit 0'
: > "$STUB_LOG"
run env PATH="$STUB_DIR:/usr/bin:/bin" "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade logi-options+' bash "$REPO_DIR"
assert_eq 0 "$RUN_STATUS" "the upgrade of a cask with no app"
assert_not_contains "$RUN_OUTPUT" "is running"
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy logi-options+"
assert_file_not_contains "$STUB_LOG" "pgrep"
cp "$SANDBOX/brew" "$STUB_DIR/brew"

# Ubuntu. Claude Code comes from elsewhere, so it doesn't update itself. The Zed cask is outdated,
# and brew upgrade skips it, as it does on macOS.
rm "$HOME/.local/bin/claude"
mv "$HOME/.local/share/claude/versions/2.0.0" "$STUB_DIR/claude"
stub brew 'case "$*" in
    upgrade) [ -z "${HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS:-}" ] || echo "(not auto_updates casks)" >> "$STUB_LOG" ;;
    "list --cask zed") ;;
    "list --cask -1") printf "font-monaspace\nzed\n" ;;
    "outdated --cask --greedy --quiet zed") echo zed; exit 1 ;;
    "list --cask"* | "bundle check"*) exit 1 ;;
esac'
stub pgrep 'exit 1'
assert_eq "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
sudo apt -o DPkg::Lock::Timeout=300 upgrade
brew update
brew upgrade
(not auto_updates casks)
brew bundle check --file=REPO/homebrew/Brewfile --no-upgrade
brew bundle install --file=REPO/homebrew/Brewfile --no-upgrade
brew list --cask -1
brew cleanup
fc-cache -f ~/.local/share/fonts
brew list --cask zed
brew outdated --cask --greedy --quiet zed
pgrep -x zed-editor
brew upgrade --cask --greedy zed
vim -Nes -u ~/.vimrc -i NONE -c PlugUpdate --sync -c qa
mise upgrade
mise hook-env --force -s bash
new-node npm update -g
uv tool upgrade --all
rustup update
brew list --cask claude
brew list --cask chatgpt
brew list --cask t3-code
brew list --cask codex
claude plugin marketplace update
claude plugin list --json
claude plugin update a@m --scope user
t3 update
codex plugin marketplace upgrade" "$(upgrade_on linux-gnu)" "commands upgrade runs on Ubuntu"

# Homebrew puts fonts in $XDG_DATA_HOME/fonts when it's set, so that's the dir to refresh
assert_contains "$(XDG_DATA_HOME="$SANDBOX/data" upgrade_on linux-gnu)" "fc-cache -f $SANDBOX/data/fonts"

# A running Zed isn't replaced, which would break it
stub pgrep '[ "$*" == "-x zed-editor" ]'
upgrade_on linux-gnu > /dev/null
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"
assert_file_contains "$SANDBOX/output" "zed is running; quit it and run upgrade again to update it."
stub pgrep 'exit 1'

# apt, mise, and t3 update fail: every stage still runs, and both functions name what failed and
# fail
stub sudo 'exit 1'
stub mise '[ "$1" != upgrade ] || exit 1; [ "$1" != hook-env ] || echo :'
stub t3 'exit 1'
: > "$STUB_LOG"
if PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade' bash "$REPO_DIR" < /dev/null > "$SANDBOX/output" 2>&1; then
    fail "upgrade succeeded with failed stages"
fi
assert_file_contains "$STUB_LOG" "rustup update"
assert_file_contains "$STUB_LOG" "codex plugin marketplace upgrade"
assert_file_contains "$SANDBOX/output" "Failed: t3 update"
assert_file_contains "$SANDBOX/output" "Failed: apt, mise, upgrade-ai-tools"
stub t3

# Discovery failures are failures too, and later independent stages still run.
stub sudo
stub claude '[ "$*" != "plugin list --json" ] || exit 2'
: > "$STUB_LOG"
assert_exit 1 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" 'claude plugin list'
assert_file_contains "$STUB_LOG" 'codex plugin marketplace upgrade'
for invalid in 'not json' '{}' ''; do
    stub claude '[ "$*" != "plugin list --json" ] || echo "'"$invalid"'"'
    assert_exit 1 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
    assert_contains "$RUN_OUTPUT" 'claude plugin list'
done

# Ctrl-C during claude plugin list stops upgrade-ai-tools, running nothing after it
stub claude '[ "$*" != "plugin list --json" ] || exit 130'
: > "$STUB_LOG"
assert_exit 130 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Interrupted; stopping."
assert_file_not_contains "$STUB_LOG" "t3 "
assert_file_not_contains "$STUB_LOG" "codex "

# mise hook-env fails, or prints nothing: npm would run the Node from before mise upgrade, so
# npm update -g doesn't run, and upgrade names the stage and fails
stub claude '[ "$*" != "plugin list --json" ] || echo "[]"'
for hook in 'exit 1' 'exit 0'; do
    stub mise '[ "$1" != hook-env ] || '"$hook"
    : > "$STUB_LOG"
    assert_exit 1 env PATH="$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade' bash "$REPO_DIR"
    assert_contains "$RUN_OUTPUT" "mise hook-env"
    assert_file_not_contains "$STUB_LOG" "npm"
    assert_file_contains "$STUB_LOG" "uv tool upgrade --all"
done
stub mise

# No installed plugins is a valid empty list, not a discovery failure.
stub claude '[ "$*" != "plugin list --json" ] || echo "[]"'
assert_exit 0 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin; upgrade_ai_tools' bash "$REPO_DIR"

# brew outdated fails, with or without output, or exits 1 without listing the cask: upgrade-ai-tools
# can't tell whether the casks are up to date, so it upgrades neither and fails, naming them. A
# successful empty answer is up to date.
upgrade_ai_tools_mac() {
    : > "$STUB_LOG"
    assert_exit "$1" env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin; upgrade_ai_tools' bash "$REPO_DIR"
}
for output in ': ; exit 42' 'echo partial; exit 42' ': ; exit 1'; do
    stub brew 'case "$*" in
        "list --cask t3-code" | "list --cask codex") ;;
        "list --cask"*) exit 1 ;;
        "outdated "*) '"$output"' ;;
    esac'
    upgrade_ai_tools_mac 1
    assert_contains "$RUN_OUTPUT" "desktop apps"
    assert_contains "$RUN_OUTPUT" "codex cask"
    assert_file_not_contains "$STUB_LOG" "brew upgrade"
done
stub brew 'case "$*" in
    "list --cask t3-code" | "list --cask codex") ;;
    "list --cask"*) exit 1 ;;
esac'
upgrade_ai_tools_mac 0
assert_file_contains "$STUB_LOG" "brew outdated --cask --greedy --quiet codex"
assert_file_not_contains "$STUB_LOG" "brew upgrade"
# brew lists both casks as outdated and exits 1, as it does for a named outdated cask: both upgrade
stub brew 'case "$*" in
    "list --cask t3-code" | "list --cask codex") ;;
    "list --cask"*) exit 1 ;;
    "outdated "*) echo "${!#}"; exit 1 ;;
    "info --json=v2 --cask t3-code") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"T3 Code.app\"]}]}]}" ;;
    "info --json=v2 --cask codex") echo "{\"casks\": [{\"artifacts\": [{\"binary\": [\"codex\"]}]}]}" ;;
esac'
upgrade_ai_tools_mac 0
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy t3-code"
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy codex"
# A running codex process, such as the ChatGPT app's app-server daemon, doesn't hold back the
# Codex CLI cask: replacing a CLI's binary doesn't break a running copy
stub pgrep 'case "$*" in *codex*) ;; *) exit 1 ;; esac'
upgrade_ai_tools_mac 0
assert_not_contains "$RUN_OUTPUT" "is running"
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy codex"
stub pgrep 'exit 1'

# A cask whose metadata can't be read, since brew info fails or prints what jq can't parse, isn't
# taken for a cask with no app: it's left alone, with no running check, and the stage fails
for info in 'exit 1' 'echo "not json"' ':' 'echo "{}"'; do
    stub brew 'case "$*" in
        "list --cask zed") ;;
        "list --cask"*) exit 1 ;;
        "outdated "*) echo "${!#}"; exit 1 ;;
        "info --json=v2 --cask zed") '"$info"' ;;
    esac'
    : > "$STUB_LOG"
    assert_exit 1 env PATH="$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade zed' bash "$REPO_DIR"
    assert_contains "$RUN_OUTPUT" "Couldn't read zed's metadata; leaving it alone."
    assert_file_not_contains "$STUB_LOG" "brew upgrade"
    assert_file_not_contains "$STUB_LOG" "pgrep"
done
# An app the cask installs elsewhere, through an explicit target, is the one checked for running
stub brew 'case "$*" in
    "list --cask zed") ;;
    "outdated "*) echo "${!#}"; exit 1 ;;
    "info --json=v2 --cask zed") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Zed.app\"], \"target\": \"/Elsewhere/Zed Preview.app\"}]}]}" ;;
esac'
: > "$STUB_LOG"
assert_exit 0 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade zed' bash "$REPO_DIR"
assert_file_contains "$STUB_LOG" 'pgrep -af ^/Elsewhere/Zed Preview[^/]*\.app/Contents/MacOS/'
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"

# A stage that exits 129, 130, or 143, as brew does when it catches Ctrl-C, stops upgrade with that
# status, running no later stage. Any other failure doesn't.
stub brew '[ "$*" != update ] || exit 130'
: > "$STUB_LOG"
assert_exit 130 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Interrupted; stopping."
assert_file_not_contains "$STUB_LOG" "brew bundle"
assert_file_not_contains "$STUB_LOG" "rustup"
stub brew '[ "$*" != update ] || exit 1'
: > "$STUB_LOG"
assert_exit 1 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade' bash "$REPO_DIR"
assert_not_contains "$RUN_OUTPUT" "Interrupted"
assert_file_contains "$STUB_LOG" "rustup update"
# upgrade-ai-tools too, here when brew is interrupted upgrading a cask
stub brew 'case "$*" in
    "list --cask claude") ;;
    "list --cask"*) exit 1 ;;
    "outdated "*) echo "${!#}"; exit 1 ;;
    "info --json=v2 --cask claude") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Claude.app\"]}]}]}" ;;
    "upgrade --cask --greedy claude") exit 130 ;;
esac'
: > "$STUB_LOG"
assert_exit 130 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade_ai_tools' bash "$REPO_DIR"
assert_file_not_contains "$STUB_LOG" "brew list --cask chatgpt"
assert_file_not_contains "$STUB_LOG" "claude plugin"
stub brew
# brew outdated and brew info stop it too when interrupted, before the next cask
for interrupted in "outdated " "info "; do
    stub brew 'case "$*" in
        "list --cask claude") ;;
        "list --cask"*) exit 1 ;;
        "'"$interrupted"'"*) exit 130 ;;
        "outdated "*) echo "${!#}"; exit 1 ;;
    esac'
    : > "$STUB_LOG"
    assert_exit 130 env PATH="$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade_ai_tools' bash "$REPO_DIR"
    assert_file_not_contains "$STUB_LOG" "brew list --cask chatgpt"
    assert_file_not_contains "$STUB_LOG" "brew upgrade"
done
stub brew

# A tmux plugin at another commit, as an older checkout or a bumped pin leaves it, moves to its
# pin, never to HEAD, and one that can't be fetched fails the tmux plugins stage
plugin="$HOME/.tmux/plugins/tmux-yank"
pin="$(git -C "$plugin" rev-parse HEAD)"
git -C "$plugin" fetch -q "$FAKE_PLUGIN_REMOTES/tmux-plugins/tmux-yank"
git -C "$plugin" checkout -q --detach FETCH_HEAD
run env PATH="$STUB_DIR:/usr/bin:/bin" "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade' bash "$REPO_DIR"
assert_eq "$pin" "$(git -C "$plugin" rev-parse HEAD)" "tmux-yank's commit after upgrade"
assert_contains "$RUN_OUTPUT" "Installed tmux plugin tmux-plugins/tmux-yank"
assert_not_contains "$RUN_OUTPUT" "Failed: tmux plugins"
rm -rf "$HOME/.tmux/plugins/tmux-open"
mv "$FAKE_PLUGIN_REMOTES/tmux-plugins/tmux-open" "$SANDBOX/tmux-open"
run env PATH="$STUB_DIR:/usr/bin:/bin" "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade' bash "$REPO_DIR"
assert_eq 1 "$RUN_STATUS" "upgrade's status with a tmux plugin it can't fetch"
assert_contains "$RUN_OUTPUT" "Failed: tmux plugins"

# zsh's upgrade and upgrade-ai-tools run the script from the repo DOTFILES_DIR names
mkdir -p "$SANDBOX/fake-repo/scripts"
# shellcheck disable=SC2016 # expanded by the fake script
printf '%s\n' 'echo "upgrade.sh $*"' > "$SANDBOX/fake-repo/scripts/upgrade.sh"
run env DOTFILES_DIR="$SANDBOX/fake-repo" zsh -f -c 'source "$1/zsh/aliases.zsh"; upgrade; upgrade-ai-tools' zsh "$REPO_DIR"
assert_eq "upgrade.sh 
upgrade.sh ai-tools" "$RUN_OUTPUT" "what zsh's functions run"
test_done
