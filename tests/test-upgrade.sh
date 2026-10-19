#!/bin/bash
set -euo pipefail

# scripts/upgrade.sh, which zsh's upgrade and upgrade-ai-tools functions run, runs each tool's
# update, in order, on each OS, with every tool stubbed: apt on Ubuntu only, the Brewfile's new
# formulae, casks added to the homebrew step, self-updating casks that aren't running, rustup from
# ~/.cargo/bin only, the plugin managers, Claude Code's own updater only for its native install,
# even with HOME reached through a symlink, Claude Code's plugins outside project, local, and
# managed scopes, with each marketplace's and plugin's version shown before and after, the t3 CLI
# only from ~/.local/bin, and brew cleanup last. A self-updating app that renamed itself is
# re-recorded in Homebrew. A failed stage doesn't stop the ones after it, and upgrade names the failed ones at the end
# and fails, but an interrupted one stops upgrade. A cask whose metadata brew can't give is left
# alone. The plugin stages move the vim and tmux plugins only to the commits the repo pins.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
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
    "list --cask -1") printf "zed\nclaude\n" ;;
    "outdated --cask --greedy --quiet "*) printf "%s\n" "${@:5}"; exit 1 ;;
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
stub mise '[ "$PWD" == "$HOME" ] || echo "mise ran in $PWD" >> "$STUB_LOG"
[ "$*" != "hook-env --force -s bash" ] || echo "export PATH='"$SANDBOX/new-node"':\$PATH"'
stub npm
mkdir -p "$SANDBOX/new-node"
printf '%s\n' '#!/bin/bash' 'echo "new-node npm $*" >> "$STUB_LOG"' > "$SANDBOX/new-node/npm"
chmod +x "$SANDBOX/new-node/npm"
stub claude '[ "$*" != "plugin list --json" ] || echo "[
    {\"id\": \"a@m\", \"scope\": \"user\"},
    {\"id\": \"b@m\", \"scope\": \"project\"},
    {\"id\": \"c@m\", \"scope\": \"local\"},
    {\"id\": \"d@m\", \"scope\": \"managed\"}
]"'
stub codex
mkdir -p "$HOME/.vim/autoload"
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
# on PATH, printing what ran, with the repo shown as REPO. DOTFILES_DIR points elsewhere, since
# upgrade finds the Brewfile from its own path.
upgrade_on() {
    : > "$STUB_LOG"
    case "$1" in
        darwin*) echo Darwin ;;
        *) echo Linux ;;
    esac > "$SANDBOX/uname-s"
    PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" DOTFILES_DIR="$SANDBOX/nowhere" \
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
# The t3 CLI the t3-code step installs
ln -s "$STUB_DIR/t3" "$HOME/.local/bin/t3"
assert_eq "brew update
brew upgrade
(not auto_updates casks)
brew bundle check --file=REPO/homebrew/Brewfile --no-upgrade
brew bundle install --file=REPO/homebrew/Brewfile --no-upgrade
brew info --json=v2 --installed --cask
brew info --json=v2 --cask rectangle
brew install --cask rectangle
brew list --cask -1
brew outdated --cask --greedy --quiet zed
brew info --json=v2 --cask zed
brew --caskroom
pgrep -af ^/Applications/Zed[^/]*\\.app/Contents/MacOS/
brew upgrade --cask --greedy zed
mas upgrade
vim -Nes -u ~/.vimrc -i NONE -c PlugUpdate --sync -c qa
mise upgrade
mise hook-env --force -s bash
new-node npm update -g
uv tool upgrade --all
rustup update
claude update
brew list --cask -1
brew outdated --cask --greedy --quiet claude
brew info --json=v2 --cask claude
brew --caskroom
pgrep -af ^/Applications/Claude[^/]*\\.app/Contents/MacOS/
claude plugin marketplace list --json
claude plugin marketplace update
claude plugin marketplace list --json
claude plugin list --json
claude plugin update a@m --scope user
claude plugin list --json
t3 update
codex plugin marketplace upgrade
brew cleanup" "$(upgrade_on darwin25.0)" "commands upgrade runs on macOS"
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

# A Brewfile that's all installed: bundle install doesn't run
cp "$STUB_DIR/brew" "$SANDBOX/brew"
stub brew 'case "$*" in
    "bundle check"*) ;;
esac'
assert_not_contains "$(upgrade_on darwin25.0)" "bundle install" "commands upgrade runs with the Brewfile installed"
assert_eq "" "$(ls -A "$TMPDIR")" "files upgrade leaves in TMPDIR"
cp "$SANDBOX/brew" "$STUB_DIR/brew"

# A cask with no app artifact, such as Logi Options+, which installs through an installer and quits
# its own app and agents first, upgrades with no running check, whatever app runs
cp "$STUB_DIR/brew" "$SANDBOX/brew"
stub brew 'case "$*" in
    "list --cask -1") printf "logi-options+\n" ;;
    "outdated --cask --greedy --quiet "*) printf "%s\n" "${@:5}"; exit 1 ;;
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
    "list --cask -1") printf "font-monaspace\nzed\n" ;;
    "outdated --cask --greedy --quiet zed") echo zed; exit 1 ;;
    "bundle check"*) exit 1 ;;
esac'
stub pgrep 'exit 1'
assert_eq "sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
sudo apt -o DPkg::Lock::Timeout=300 upgrade
brew update
brew upgrade
(not auto_updates casks)
brew bundle check --file=REPO/homebrew/Brewfile --no-upgrade
brew bundle install --file=REPO/homebrew/Brewfile --no-upgrade
brew list --cask -1
fc-cache -f ~/.local/share/fonts
brew list --cask -1
brew outdated --cask --greedy --quiet zed
pgrep -x zed-editor
brew upgrade --cask --greedy zed
vim -Nes -u ~/.vimrc -i NONE -c PlugUpdate --sync -c qa
mise upgrade
mise hook-env --force -s bash
new-node npm update -g
uv tool upgrade --all
rustup update
brew list --cask -1
claude plugin marketplace list --json
claude plugin marketplace update
claude plugin marketplace list --json
claude plugin list --json
claude plugin update a@m --scope user
claude plugin list --json
t3 update
codex plugin marketplace upgrade
brew cleanup" "$(upgrade_on linux-gnu)" "commands upgrade runs on Ubuntu"

# A running Zed isn't replaced, which would break it
stub pgrep '[ "$*" == "-x zed-editor" ]'
upgrade_on linux-gnu > /dev/null
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"
assert_file_contains "$SANDBOX/output" "zed is running; quit it and run upgrade again to update it."
stub pgrep 'exit 1'

# apt, mise, and t3 update fail: every stage still runs, and upgrade names them all, the AI tools'
# stage among them, once at the end, and fails
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
assert_eq "Failed: apt, mise, t3 update" "$(grep '^Failed' "$SANDBOX/output")" "upgrade's list of failed stages"
stub t3

# Discovery failures are failures too, and later independent stages still run.
stub sudo
stub claude '[ "$*" != "plugin list --json" ] || exit 2'
: > "$STUB_LOG"
assert_exit 1 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" 'claude plugin list'
assert_file_contains "$STUB_LOG" 'codex plugin marketplace upgrade'

# Since plugins can add hooks that run as you, each Claude Code marketplace's commit and each
# updated plugin's version show before and after the update. A marketplace that isn't a git
# checkout has no version, and a plugin that isn't updated isn't shown. A project's copy of an
# updated plugin, listed first, doesn't stand in for its version after.
market="$SANDBOX/market"
git init -q "$market"
git_commit "$market" --allow-empty -m one
old_commit="$(git -C "$market" rev-parse --short=12 HEAD)"
echo 1.0.0 > "$SANDBOX/plugin-version"
stub claude 'case "$*" in
    "plugin marketplace list --json") echo "[{\"name\": \"m\", \"installLocation\": \"'"$market"'\"}, {\"name\": \"dir\", \"installLocation\": \"'"$SANDBOX"'\"}]" ;;
    "plugin marketplace update") git -C "'"$market"'" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two ;;
    "plugin list --json") echo "[{\"id\": \"a@m\", \"scope\": \"project\", \"version\": \"0.9.0\"},
        {\"id\": \"a@m\", \"scope\": \"user\", \"version\": \"$(cat "'"$SANDBOX"'/plugin-version")\"},
        {\"id\": \"b@m\", \"scope\": \"user\", \"version\": \"2.0.0\"}, {\"id\": \"c@m\", \"scope\": \"project\", \"version\": \"3.0.0\"}]" ;;
    "plugin update a@m "*) echo 1.1.0 > "'"$SANDBOX"'/plugin-version" ;;
esac'
assert_exit 0 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Claude Code marketplaces:
  m: $old_commit -> $(git -C "$market" rev-parse --short=12 HEAD)
  dir: -
"
assert_contains "$RUN_OUTPUT" "Claude Code plugins:
  a@m: 1.0.0 -> 1.1.0
  b@m: 2.0.0"
assert_not_contains "$RUN_OUTPUT" "c@m"

# Ctrl-C during claude plugin list stops upgrade-ai-tools, running nothing after it
stub claude '[ "$*" != "plugin list --json" ] || exit 130'
: > "$STUB_LOG"
assert_exit 130 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Interrupted; stopping."
assert_file_not_contains "$STUB_LOG" "t3 "
assert_file_not_contains "$STUB_LOG" "codex "

# A t3 elsewhere on PATH, such as the ~/.t3/bin/t3 the macOS app writes to run its own server,
# isn't updated: the app updates itself
stub claude '[ "$*" != "plugin list --json" ] || echo "[]"'
mv "$HOME/.local/bin/t3" "$SANDBOX/t3-link"
: > "$STUB_LOG"
assert_exit 0 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade_ai_tools' bash "$REPO_DIR"
assert_file_not_contains "$STUB_LOG" "t3 update"
mv "$SANDBOX/t3-link" "$HOME/.local/bin/t3"

# mise hook-env fails: npm would run the Node from before mise upgrade, so npm update -g doesn't
# run, and upgrade names the stage and fails
stub claude '[ "$*" != "plugin list --json" ] || echo "[]"'
stub mise '[ "$1" != hook-env ] || exit 1'
: > "$STUB_LOG"
assert_exit 1 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "mise hook-env"
assert_file_not_contains "$STUB_LOG" "npm"
assert_file_contains "$STUB_LOG" "uv tool upgrade --all"
stub mise

# brew outdated exits 1 without listing the cask: upgrade-ai-tools can't tell whether the casks are
# up to date, so it asks for each alone, upgrades neither, and fails, naming them. A successful empty answer is up to
# date.
upgrade_ai_tools_mac() {
    : > "$STUB_LOG"
    assert_exit "$1" env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin; upgrade_ai_tools' bash "$REPO_DIR"
}
stub brew 'case "$*" in
    "list --cask -1") printf "t3-code\ncodex\n" ;;
    "outdated "*) exit 1 ;;
esac'
upgrade_ai_tools_mac 1
assert_contains "$RUN_OUTPUT" "Couldn't check whether t3-code is up to date"
assert_contains "$RUN_OUTPUT" "Couldn't check whether codex is up to date"
assert_contains "$RUN_OUTPUT" "Failed: AI casks"
assert_file_not_contains "$STUB_LOG" "brew upgrade"
stub brew 'case "$*" in
    "list --cask -1") printf "t3-code\ncodex\n" ;;
esac'
upgrade_ai_tools_mac 0
assert_file_contains "$STUB_LOG" "brew outdated --cask --greedy --quiet t3-code codex"
assert_file_not_contains "$STUB_LOG" "brew upgrade"
# brew lists both casks as outdated and exits 1, as it does for a named outdated cask: both upgrade
stub brew 'case "$*" in
    "list --cask -1") printf "t3-code\ncodex\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
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

# brew list --cask fails: no cask counts as installed, so the stage upgrades none and fails,
# naming the listing, and the stages after it still run
stub brew '[ "$*" != "list --cask -1" ] || exit 1'
upgrade_ai_tools_mac 1
assert_contains "$RUN_OUTPUT" "Couldn't list the installed casks"
assert_contains "$RUN_OUTPUT" "Failed: AI casks"
assert_file_not_contains "$STUB_LOG" "brew outdated"
assert_file_contains "$STUB_LOG" "codex plugin marketplace upgrade"

# One brew list and one brew outdated cover a stage's casks, and only the installed ones are asked
# about. brew outdated may name a cask after its tap.
stub brew 'case "$*" in
    "list --cask -1") printf "zed\nappcleaner\nthe-unarchiver\n" ;;
    "outdated "*) echo homebrew/cask/zed; echo the-unarchiver; exit 1 ;;
    "info --json=v2 --cask "*) echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"$4.app\"]}]}]}" ;;
esac'
stub pgrep 'exit 1'
: > "$STUB_LOG"
assert_exit 0 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade zed appcleaner the-unarchiver logi-options+' bash "$REPO_DIR"
assert_eq "brew list --cask -1
brew outdated --cask --greedy --quiet zed appcleaner the-unarchiver
brew upgrade --cask --greedy zed
brew upgrade --cask --greedy the-unarchiver" "$(grep -E '^brew (list|outdated|upgrade)' "$STUB_LOG")" "brew calls for a stage's casks"

# A cask brew can't find, such as one removed upstream, fails a query that names it. Each cask is
# then asked alone: the others still upgrade, and the stage fails naming that one.
stub brew 'case "$*" in
    "list --cask -1") printf "zed\ngone-cask\nthe-unarchiver\n" ;;
    "outdated "*gone-cask*) echo "Error: Cask '\''gone-cask'\'' is unavailable" >&2; exit 1 ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask "*) echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"$4.app\"]}]}]}" ;;
esac'
: > "$STUB_LOG"
assert_exit 1 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade zed gone-cask the-unarchiver' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Couldn't check whether gone-cask is up to date"
assert_eq "brew upgrade --cask --greedy zed
brew upgrade --cask --greedy the-unarchiver" "$(grep '^brew upgrade' "$STUB_LOG")" "upgrades beside a cask brew can't find"

# A cask whose metadata can't be read, since brew info fails or prints what jq can't parse, isn't
# taken for a cask with no app: it's left alone, with no running check, and the stage fails
for info in 'exit 1' 'echo "{}"'; do
    stub brew 'case "$*" in
        "list --cask -1") printf "zed\n" ;;
        "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
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
    "list --cask -1") printf "zed\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask zed") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Zed.app\"], \"target\": \"/Elsewhere/Zed Preview.app\"}]}]}" ;;
esac'
: > "$STUB_LOG"
assert_exit 0 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade zed' bash "$REPO_DIR"
assert_file_contains "$STUB_LOG" 'pgrep -af ^/Elsewhere/Zed Preview[^/]*\.app/Contents/MacOS/'
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"
# The app's path matches only itself: a . in it doesn't match another app's character, so another
# running app doesn't hold the cask back
stub brew 'case "$*" in
    "list --cask -1") printf "zed\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask zed") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Zed.app\"], \"target\": \"/Elsewhere/Zed.Dev.app\"}]}]}" ;;
esac'
stub pgrep 'echo "/Elsewhere/ZedxDev.app/Contents/MacOS/zed" | grep -E -- "${!#}"'
assert_exit 0 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade zed' bash "$REPO_DIR"
assert_not_contains "$RUN_OUTPUT" "is running"

# An app that renamed itself as it updated, as T3 Code (Alpha) did to T3 Code (Beta), is re-recorded
# in place, even while it runs, since brew upgrade would stop on the app it recorded being gone.
# brew's install receipt names the old app. A receipt whose uninstall does more than remove the
# app, or names an app that's still there, gets the usual upgrade.
mkdir -p "$SANDBOX/caskroom/t3-code/.metadata" "$SANDBOX/Applications/T3 Code (Beta).app"
receipt() {
    printf '{"uninstall_artifacts": %s}\n' "$1" > "$SANDBOX/caskroom/t3-code/.metadata/INSTALL_RECEIPT.json"
}
stub brew 'case "$*" in
    "list --cask -1") printf "t3-code\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask t3-code") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"T3 Code (Beta).app\"], \"target\": \"'"$SANDBOX"'/Applications/T3 Code (Beta).app\"}]}]}" ;;
    --caskroom) echo "'"$SANDBOX"'/caskroom" ;;
esac'
stub pgrep
upgrade_t3_cask() {
    : > "$STUB_LOG"
    assert_exit 0 env PATH="$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade-ai-tools t3-code' bash "$REPO_DIR"
}
receipt '[{"app": ["T3 Code (Alpha).app"]}, {"zap": [{"trash": ["~/.t3/userdata"]}]}]'
upgrade_t3_cask
assert_contains "$RUN_OUTPUT" "T3 Code (Beta).app renamed itself as it updated"
assert_file_contains "$STUB_LOG" "brew uninstall --cask --force t3-code"
assert_file_contains "$STUB_LOG" "brew install --cask --adopt t3-code"
assert_file_not_contains "$STUB_LOG" "brew upgrade"
assert_file_not_contains "$STUB_LOG" "pgrep"
for artifacts in '[{"app": ["T3 Code (Alpha).app"]}, {"quit": ["com.t3tools.t3code"]}]' \
    '[{"app": ["T3 Code (Beta).app"]}]'; do
    receipt "$artifacts"
    upgrade_t3_cask
    assert_file_not_contains "$STUB_LOG" "brew uninstall"
    assert_contains "$RUN_OUTPUT" "T3 Code is running"
done
stub pgrep 'exit 1'
receipt '[{"app": ["T3 Code (Alpha).app"]}]'
stub brew 'case "$*" in
    "list --cask -1") printf "t3-code\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask t3-code") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"T3 Code (Beta).app\"], \"target\": \"'"$SANDBOX"'/Applications/T3 Code (Beta).app\"}]}]}" ;;
    --caskroom) echo "'"$SANDBOX"'/caskroom" ;;
    "install "*) exit 1 ;;
esac'
: > "$STUB_LOG"
assert_exit 1 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade-ai-tools t3-code' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Couldn't re-record t3-code. Run: brew install --cask --adopt t3-code"

# A stage that exits 129, 130, or 143, as brew does when it catches Ctrl-C, stops upgrade with that
# status, running no later stage
stub brew '[ "$*" != update ] || exit 130'
: > "$STUB_LOG"
assert_exit 130 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Interrupted; stopping."
assert_file_not_contains "$STUB_LOG" "brew bundle"
assert_file_not_contains "$STUB_LOG" "rustup"
# upgrade-ai-tools too, here when brew is interrupted upgrading a cask: the casks after it aren't
# upgraded
stub brew 'case "$*" in
    "list --cask -1") printf "claude\ncodex\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask claude") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Claude.app\"]}]}]}" ;;
    "upgrade --cask --greedy claude") exit 130 ;;
esac'
: > "$STUB_LOG"
assert_exit 130 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade_ai_tools' bash "$REPO_DIR"
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy claude"
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy codex"
assert_file_not_contains "$STUB_LOG" "claude plugin"
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
test_done
