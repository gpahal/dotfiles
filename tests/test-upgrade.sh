#!/bin/bash
set -euo pipefail

# scripts/upgrade.sh: a failed stage doesn't stop later ones; an interrupted one stops upgrade.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
JQ="$(command -v jq)"

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
# rectangle is missing, as for a cask added since setup ran
# shellcheck disable=SC2046 # one word per cask
installed_json $(grep -vx rectangle <<< "$HOMEBREW_CASKS") > "$SANDBOX/installed.json"

# Like Homebrew, `brew outdated` exits 1 when it lists a cask it was given
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
# rustup's installer puts it in ~/.cargo/bin, off PATH
mkdir -p "$HOME/.cargo/bin"
mv "$STUB_DIR/rustup" "$HOME/.cargo/bin/rustup"
# mise must run from ~, away from a project's mise.toml; hook-env puts the "new Node" first on PATH
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
fake_tmux_plugins
"$BASH" -c 'source "$1/tmux/install.sh" && sync_tmux_plugins' bash "$REPO_DIR" > /dev/null
# uname -s follows upgrade_on's OS so is_macos agrees with OSTYPE; unlike a stub, it doesn't log
printf '%s\n' '#!/bin/bash' '[ "$1" != -s ] || exec cat "'"$SANDBOX"'/uname-s"' 'exec /usr/bin/uname "$@"' > "$STUB_DIR/uname"
chmod +x "$STUB_DIR/uname"
echo Darwin > "$SANDBOX/uname-s"

# DOTFILES_DIR points elsewhere: upgrade finds the Brewfile from its own path
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

# Drops read-only queries only, so an unexpected write still fails
upgrade_actions() {
    upgrade_on "$1" | sed -E '/^(brew (bundle check|info|list|outdated|--caskroom)|pgrep |claude plugin (marketplace list|list) )/d'
}

# macOS, with Claude Code's native install
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
mv "$STUB_DIR/claude" "$HOME/.local/share/claude/versions/2.0.0"
ln -s "$HOME/.local/share/claude/versions/2.0.0" "$HOME/.local/bin/claude"
ln -s "$STUB_DIR/t3" "$HOME/.local/bin/t3"
assert_eq "brew update
brew upgrade
(not auto_updates casks)
brew bundle install --file=REPO/homebrew/Brewfile --no-upgrade
brew install --cask rectangle
brew upgrade --cask --greedy zed
mas upgrade
vim -Nes -u ~/.vimrc -i NONE -c PlugUpdate --sync -c qa
mise upgrade
mise hook-env --force -s bash
new-node npm update -g
uv tool upgrade --all
rustup update
claude update
claude plugin marketplace update
claude plugin update a@m --scope user
t3 update
codex plugin marketplace upgrade
brew cleanup" "$(upgrade_actions darwin25.0)" "commands upgrade runs on macOS"
assert_file_contains "$SANDBOX/output" "Claude is running; quit it and run upgrade-ai-tools again to update it."

# HOME through a symlink
ln -s "$HOME" "$SANDBOX/home-link"
: > "$STUB_LOG"
env HOME="$SANDBOX/home-link" PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade_ai_tools' bash "$REPO_DIR" \
    < /dev/null > "$SANDBOX/output" 2>&1 || true
assert_file_contains "$STUB_LOG" "claude update"

# A rustup elsewhere on PATH isn't the runtimes step's
mv "$HOME/.cargo/bin/rustup" "$STUB_DIR/rustup"
assert_not_contains "$(upgrade_on darwin25.0)" "rustup" "commands upgrade runs with rustup only on PATH"
mv "$STUB_DIR/rustup" "$HOME/.cargo/bin/rustup"

cp "$STUB_DIR/brew" "$SANDBOX/brew"
stub brew 'case "$*" in
    "bundle check"*) ;;
esac'
assert_not_contains "$(upgrade_on darwin25.0)" "bundle install" "commands upgrade runs with the Brewfile installed"
assert_eq "" "$(find "$TMPDIR" -maxdepth 1 -name 'tmp.*' -print)" "temporary files upgrade leaves behind"
cp "$SANDBOX/brew" "$STUB_DIR/brew"

# A cask with no app artifact (Logi Options+) quits its own app, so no running check
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

# Ubuntu, where Claude Code doesn't update itself
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
brew bundle install --file=REPO/homebrew/Brewfile --no-upgrade
fc-cache -f ~/.local/share/fonts
brew upgrade --cask --greedy zed
vim -Nes -u ~/.vimrc -i NONE -c PlugUpdate --sync -c qa
mise upgrade
mise hook-env --force -s bash
new-node npm update -g
uv tool upgrade --all
rustup update
claude plugin marketplace update
claude plugin update a@m --scope user
t3 update
codex plugin marketplace upgrade
brew cleanup" "$(upgrade_actions linux-gnu)" "commands upgrade runs on Ubuntu"

# Replacing a running Zed would break it
stub pgrep '[ "$*" == "-x zed-editor" ]'
upgrade_on linux-gnu > /dev/null
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"
assert_file_contains "$SANDBOX/output" "zed is running; quit it and run upgrade again to update it."
stub pgrep 'exit 1'

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

stub sudo
stub claude '[ "$*" != "plugin list --json" ] || exit 2'
: > "$STUB_LOG"
assert_exit 1 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" 'claude plugin list'
assert_file_contains "$STUB_LOG" 'codex plugin marketplace upgrade'

# Plugins can add hooks, so versions show before and after; a project's copy (listed first)
# doesn't stand in for the user-scope one
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

stub claude '[ "$*" != "plugin list --json" ] || exit 130'
: > "$STUB_LOG"
assert_exit 130 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade_ai_tools' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Interrupted; stopping."
assert_file_not_contains "$STUB_LOG" "t3 "
assert_file_not_contains "$STUB_LOG" "codex "

# A t3 elsewhere on PATH, such as the macOS app's ~/.t3/bin/t3, updates itself
stub claude '[ "$*" != "plugin list --json" ] || echo "[]"'
mv "$HOME/.local/bin/t3" "$SANDBOX/t3-link"
: > "$STUB_LOG"
assert_exit 0 env PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade_ai_tools' bash "$REPO_DIR"
assert_file_not_contains "$STUB_LOG" "t3 update"
mv "$SANDBOX/t3-link" "$HOME/.local/bin/t3"

# Without hook-env, npm would run the old Node
stub claude '[ "$*" != "plugin list --json" ] || echo "[]"'
stub mise '[ "$1" != hook-env ] || exit 1'
: > "$STUB_LOG"
assert_exit 1 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=linux-gnu; upgrade' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "mise hook-env"
assert_file_not_contains "$STUB_LOG" "npm"
assert_file_contains "$STUB_LOG" "uv tool upgrade --all"
stub mise

# brew outdated also exits 1 on error, so an exit 1 listing nothing is a failure
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
stub brew 'case "$*" in
    "list --cask -1") printf "t3-code\ncodex\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask t3-code") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"T3 Code.app\"]}]}]}" ;;
    "info --json=v2 --cask codex") echo "{\"casks\": [{\"artifacts\": [{\"binary\": [\"codex\"]}]}]}" ;;
esac'
upgrade_ai_tools_mac 0
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy t3-code"
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy codex"
# Replacing a CLI's binary doesn't break a running copy, such as the ChatGPT app's codex daemon
stub pgrep 'case "$*" in *codex*) ;; *) exit 1 ;; esac'
upgrade_ai_tools_mac 0
assert_not_contains "$RUN_OUTPUT" "is running"
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy codex"
stub pgrep 'exit 1'

stub brew '[ "$*" != "list --cask -1" ] || exit 1'
upgrade_ai_tools_mac 1
assert_contains "$RUN_OUTPUT" "Couldn't list the installed casks"
assert_contains "$RUN_OUTPUT" "Failed: AI casks"
assert_file_not_contains "$STUB_LOG" "brew outdated"
assert_file_contains "$STUB_LOG" "codex plugin marketplace upgrade"

# brew outdated may name a cask after its tap
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

# A cask removed upstream fails any query naming it, so each is then asked alone
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

# Unreadable metadata mustn't pass for a cask with no app
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
# An explicit target is the app checked for running
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
# A . in the app's path is escaped in pgrep's regex
stub brew 'case "$*" in
    "list --cask -1") printf "zed\n" ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask zed") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Zed.app\"], \"target\": \"/Elsewhere/Zed.Dev.app\"}]}]}" ;;
esac'
stub pgrep 'echo "/Elsewhere/ZedxDev.app/Contents/MacOS/zed" | grep -E -- "${!#}"'
assert_exit 0 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; _upgrade_self_updating_casks upgrade zed' bash "$REPO_DIR"
assert_not_contains "$RUN_OUTPUT" "is running"

# An app that renamed itself (T3 Code Alpha to Beta) is re-recorded, since brew upgrade stops on
# the recorded app being gone; a receipt that does more than remove the app gets the usual upgrade
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

# brew exits 129, 130, or 143 when it catches Ctrl-C
stub brew '[ "$*" != update ] || exit 130'
: > "$STUB_LOG"
assert_exit 130 env PATH="$STUB_DIR:/usr/bin:/bin" \
    "$BASH" -c 'source "$1/scripts/upgrade.sh"; OSTYPE=darwin25.0; upgrade' bash "$REPO_DIR"
assert_contains "$RUN_OUTPUT" "Interrupted; stopping."
assert_file_not_contains "$STUB_LOG" "brew bundle"
assert_file_not_contains "$STUB_LOG" "rustup"
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

# A tmux plugin moves to its pin, never to HEAD
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
