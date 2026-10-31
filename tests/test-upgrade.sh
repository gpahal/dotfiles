#!/bin/bash

# scripts/upgrade.sh: a failed stage doesn't stop later ones; an interrupted one stops upgrade.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
    "info --json=v2 --installed --cask") cat "$SANDBOX/installed.json" ;;
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
for cmd in mas vim uv t3 fc-cache; do
    stub "$cmd"
done
# rustup's installer puts it in ~/.cargo/bin, off PATH
stub_at "$HOME/.cargo/bin/rustup"
# mise must run from ~, away from a project's mise.toml; hook-env puts the "new Node" first on PATH
stub mise '[ "$PWD" == "$HOME" ] || echo "mise ran in $PWD" >> "$STUB_LOG"
[ "$*" != "hook-env --force -s bash" ] || echo "export PATH='"$SANDBOX/new-node"':\$PATH"'
stub npm
mkdir -p "$SANDBOX/new-node"
printf '%s\n' '#!/bin/bash' 'echo "new-node npm $*" >> "$STUB_LOG"' > "$SANDBOX/new-node/npm"
chmod +x "$SANDBOX/new-node/npm"
# Claude Code's native install
stub_at "$HOME/.local/share/claude/versions/2.0.0" '[ "$*" != "plugin list --json" ] || echo "[
    {\"id\": \"a@m\", \"scope\": \"user\"},
    {\"id\": \"b@m\", \"scope\": \"project\"},
    {\"id\": \"c@m\", \"scope\": \"local\"},
    {\"id\": \"d@m\", \"scope\": \"managed\"}
]"'
stub codex
# ntfy's notifier: the LaunchAgent loaded, or the user unit active, while these files exist
stub launchctl '[ "$1" != print ] || [ -e "$SANDBOX/agent-loaded" ]'
stub systemctl '[ "$2" != is-active ] || [ -e "$SANDBOX/notifier-active" ]'
mkdir -p "$HOME/.vim/autoload"
touch "$HOME/.vimrc" "$HOME/.vim/autoload/plug.vim"
# Darwin unless a case says Linux, and it doesn't log
stub_uname Darwin

# upgrade_run <fn> [arg...]: runs upgrade.sh's function on a fresh $STUB_LOG
upgrade_run() {
    : > "$STUB_LOG"
    PATH="$HOME/.local/bin:$STUB_DIR:/usr/bin:/bin" \
        "$BASH" -c 'source "$1/scripts/upgrade.sh"; "${@:2}"' bash "$REPO_DIR" "$@"
}

# DOTFILES_DIR points elsewhere: upgrade finds the Brewfile from its own path
upgrade_on() {
    stub_uname "$1"
    DOTFILES_DIR="$SANDBOX/nowhere" upgrade_run upgrade > "$SANDBOX/output" 2>&1 || {
        fail "upgrade failed on $1:"
        _show "$(cat "$SANDBOX/output")"
    }
    stub_uname Darwin
}

# A brew with casks $1 installed and outdated, each an app named after it. Case arms on "$*" in $2
# come first, so they can override these.
stub_brew_casks() {
    stub brew 'case "$*" in
'"${2:-}"'
    "list --cask -1") printf "%s\n" '"$1"' ;;
    "outdated "*) printf "%s\n" "${@:5}"; exit 1 ;;
    "info --json=v2 --cask "*) echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"$4.app\"]}]}]}" ;;
esac'
}

# macOS, with Claude Code's native install
mkdir -p "$HOME/.local/bin"
ln -s "$HOME/.local/share/claude/versions/2.0.0" "$HOME/.local/bin/claude"
ln -s "$STUB_DIR/t3" "$HOME/.local/bin/t3"
upgrade_on Darwin
# brew upgrade leaves casks that update themselves to their own updaters
assert_file_contains "$STUB_LOG" "(not auto_updates casks)"
assert_file_contains "$STUB_LOG" "brew install --cask rectangle"
# Replacing a running app would break it
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy claude"
assert_eq "claude plugin update a@m --scope user" "$(grep '^claude plugin update' "$STUB_LOG")" \
    "plugin updates upgrade runs"
assert_eq "mise upgrade
mise hook-env --force -s bash
new-node npm update -g" "$(grep -E '^(mise|npm|new-node npm) ' "$STUB_LOG")" "mise and npm commands upgrade runs"
assert_file_not_contains "$STUB_LOG" "mise ran in"
assert_eq "brew cleanup" "$(tail -n 1 "$STUB_LOG")" "upgrade's last command"
assert_file_not_contains "$STUB_LOG" "launchctl kickstart"

# The notifier restarts on the upgraded ntfy, after brew upgrades it
touch "$SANDBOX/agent-loaded"
upgrade_on Darwin
assert_file_contains "$STUB_LOG" "launchctl kickstart -k gui/$(id -u)/dotfiles.ntfy-subscribe"
[ "$(grep -n 'launchctl kickstart' "$STUB_LOG" | cut -d: -f1)" -gt "$(grep -n '^brew upgrade' "$STUB_LOG" | head -n 1 | cut -d: -f1)" ] ||
    fail "the notifier restarted before brew upgrade"
rm "$SANDBOX/agent-loaded"

# HOME through a symlink
ln -s "$HOME" "$SANDBOX/home-link"
HOME="$SANDBOX/home-link" upgrade_run upgrade_ai_tools > /dev/null 2>&1 || true
assert_file_contains "$STUB_LOG" "claude update"

# A rustup elsewhere on PATH isn't the runtimes step's
mv "$HOME/.cargo/bin/rustup" "$STUB_DIR/rustup"
upgrade_on Darwin
assert_file_not_contains "$STUB_LOG" "rustup"
mv "$STUB_DIR/rustup" "$HOME/.cargo/bin/rustup"

# Ubuntu, with a claude other than the native install, which upgrade doesn't update
rm "$HOME/.local/bin/claude"
mv "$HOME/.local/share/claude/versions/2.0.0" "$STUB_DIR/claude"
stub brew 'case "$*" in
    "list --cask -1") printf "font-monaspace\nzed\n" ;;
    "outdated --cask --greedy --quiet "*" zed"*) echo zed; exit 1 ;;
    "bundle check"*) exit 1 ;;
esac'
stub pgrep 'exit 1'
upgrade_on Linux
assert_eq "apt-get update
apt upgrade" "$(sed -nE 's/^sudo .*(apt-get|apt) .* (update|upgrade)$/\1 \2/p' "$STUB_LOG")" \
    "apt commands upgrade runs"
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"
assert_file_not_contains "$STUB_LOG" "claude update"
assert_file_not_contains "$STUB_LOG" "systemctl --user restart"
touch "$SANDBOX/notifier-active"
upgrade_on Linux
assert_file_contains "$STUB_LOG" "systemctl --user restart dotfiles-ntfy-notify.service"
rm "$SANDBOX/notifier-active"

# Replacing a running Zed would break it
stub pgrep '[ "$*" == "-x zed-editor" ]'
upgrade_on Linux
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"
stub pgrep 'exit 1'

stub_uname Linux
stub sudo 'exit 1'
stub mise '[ "$1" != upgrade ] || exit 1; [ "$1" != hook-env ] || echo :'
stub t3 'exit 1'
assert_exit 1 upgrade_run upgrade
assert_file_contains "$STUB_LOG" "rustup update"
assert_file_contains "$STUB_LOG" "codex plugin marketplace upgrade"
assert_eq "Failed: apt, mise, t3 update" "$(grep '^Failed' <<< "$RUN_OUTPUT")" "upgrade's list of failed stages"
stub t3
stub sudo

# Plugins can add hooks, so versions show before and after; a project's copy (listed first)
# doesn't stand in for the user-scope one
market="$SANDBOX/market"
git init -q "$market"
git_commit "$market" --allow-empty -m one
old_commit="$(git -C "$market" rev-parse --short=12 HEAD)"
echo 1.0.0 > "$SANDBOX/plugin-version"
stub claude 'case "$*" in
    "plugin marketplace list --json") echo "[{\"name\": \"m\", \"installLocation\": \"'"$market"'\"}, {\"name\": \"dir\", \"installLocation\": \"$SANDBOX\"}]" ;;
    "plugin marketplace update") git -C "'"$market"'" commit -q --allow-empty -m two ;;
    "plugin list --json") echo "[{\"id\": \"a@m\", \"scope\": \"project\", \"version\": \"0.9.0\"},
        {\"id\": \"a@m\", \"scope\": \"user\", \"version\": \"$(cat "$SANDBOX/plugin-version")\"},
        {\"id\": \"b@m\", \"scope\": \"user\", \"version\": \"2.0.0\"}, {\"id\": \"c@m\", \"scope\": \"project\", \"version\": \"3.0.0\"}]" ;;
    "plugin update a@m "*) echo 1.1.0 > "$SANDBOX/plugin-version" ;;
esac'
assert_exit 0 upgrade_run upgrade_ai_tools
assert_contains "$RUN_OUTPUT" "Claude Code marketplaces:
  m: $old_commit -> $(git -C "$market" rev-parse --short=12 HEAD)
  dir: -
"
assert_contains "$RUN_OUTPUT" "Claude Code plugins:
  a@m: 1.0.0 -> 1.1.0
  b@m: 2.0.0"
assert_not_contains "$RUN_OUTPUT" "c@m"

# A t3 elsewhere on PATH, such as the macOS app's ~/.t3/bin/t3, updates itself
stub_uname Darwin
stub claude '[ "$*" != "plugin list --json" ] || echo "[]"'
mv "$HOME/.local/bin/t3" "$SANDBOX/t3-link"
assert_exit 0 upgrade_run upgrade_ai_tools
assert_file_not_contains "$STUB_LOG" "t3 update"
mv "$SANDBOX/t3-link" "$HOME/.local/bin/t3"

# Without hook-env, npm would run the old Node
stub_uname Linux
stub mise '[ "$1" != hook-env ] || exit 1'
assert_exit 1 upgrade_run upgrade
assert_contains "$(grep '^Failed' <<< "$RUN_OUTPUT")" "mise hook-env"
assert_file_not_contains "$STUB_LOG" "npm"
assert_file_contains "$STUB_LOG" "uv tool upgrade --all"
stub mise
stub_uname Darwin

# Replacing a CLI's binary doesn't break a running copy, such as the ChatGPT app's codex daemon
stub_brew_casks "t3-code codex" \
    '"info --json=v2 --cask codex") echo "{\"casks\": [{\"artifacts\": [{\"binary\": [\"codex\"]}]}]}" ;;'
stub pgrep 'case "$*" in *codex*) ;; *) exit 1 ;; esac'
assert_exit 0 upgrade_run upgrade_ai_tools
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy codex"
stub pgrep 'exit 1'

# upgrade's pass covers every installed cask but the AI ones. A running app is quit, upgraded, and
# opened again by bundle ID, but never Ghostty, the terminal upgrade likely runs in.
stub_brew_casks "google-chrome rectangle ghostty claude"
stub defaults 'echo "com.example.$(basename "$(dirname "$(dirname "$2")")" .app)"'
stub osascript 'touch "$SANDBOX/quit"'
stub open
stub sleep
stub pgrep 'case "$*" in *ghostty*) ;; *google-chrome*) [ ! -e "$SANDBOX/quit" ] ;; *) exit 1 ;; esac'
assert_exit 0 upgrade_run _upgrade_installed_casks
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy rectangle"
assert_eq "osascript -e with timeout of 20 seconds -e quit app id \"com.example.google-chrome\" -e end timeout
brew upgrade --cask --greedy google-chrome
open -g -b com.example.google-chrome" "$(grep -E '^(osascript|brew upgrade --cask --greedy google-chrome|open)' "$STUB_LOG")" \
    "quitting, upgrading, and reopening a running app, in order"
assert_contains "$RUN_OUTPUT" "Quitting google-chrome to update it; it opens again after."
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy ghostty"
assert_file_not_contains "$STUB_LOG" "com.example.ghostty"
assert_file_not_contains "$STUB_LOG" "claude"
assert_contains "$RUN_OUTPUT" "Running, so not updated: ghostty. Quit them and run upgrade again."
# An app that won't quit, as one asking to save, is left running and as it was
rm "$SANDBOX/quit"
for quit in 'exit 1' ':'; do
    stub osascript "$quit"
    assert_exit 0 upgrade_run _upgrade_installed_casks
    assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy google-chrome"
    assert_file_not_contains "$STUB_LOG" "open -g"
    assert_contains "$RUN_OUTPUT" "Running, so not updated: google-chrome, ghostty."
done
stub pgrep 'exit 1'

# A cask with no app artifact (Logi Options+) quits its own app, so no running check
stub_brew_casks logi-options+ \
    '"info --json=v2 --cask logi-options+") echo "{\"casks\": [{\"artifacts\": [{\"installer\": [{\"manual\": \"x\"}]}, {\"uninstall\": []}, {\"zap\": []}]}]}" ;;'
stub pgrep 'exit 0'
assert_exit 0 upgrade_run _upgrade_self_updating_casks upgrade logi-options+
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy logi-options+"
assert_file_not_contains "$STUB_LOG" "pgrep"
stub pgrep 'exit 1'

# Unreadable metadata mustn't pass for a cask with no app
for info in 'exit 1' 'echo "{}"'; do
    stub_brew_casks zed '"info --json=v2 --cask zed") '"$info"' ;;'
    assert_exit 1 upgrade_run _upgrade_self_updating_casks upgrade zed
    assert_file_not_contains "$STUB_LOG" "brew upgrade"
    assert_file_not_contains "$STUB_LOG" "pgrep"
done
# An explicit target is the app checked for running
stub_brew_casks zed \
    '"info --json=v2 --cask zed") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"Zed.app\"], \"target\": \"/Elsewhere/Zed Preview.app\"}]}]}" ;;'
assert_exit 0 upgrade_run _upgrade_self_updating_casks upgrade zed
assert_file_contains "$STUB_LOG" 'pgrep -af ^/Elsewhere/Zed Preview[^/]*\.app/Contents/MacOS/'
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy zed"

# An app that renamed itself is re-recorded, since brew upgrade stops on
# the recorded app being gone; a receipt that does more than remove the app gets the usual upgrade
mkdir -p "$SANDBOX/caskroom/t3-code/.metadata" "$SANDBOX/Applications/T3 Code (Beta).app"
receipt() {
    printf '{"uninstall_artifacts": %s}\n' "$1" > "$SANDBOX/caskroom/t3-code/.metadata/INSTALL_RECEIPT.json"
}
t3_cask='"info --json=v2 --cask t3-code") echo "{\"casks\": [{\"artifacts\": [{\"app\": [\"T3 Code (Beta).app\"], \"target\": \"$SANDBOX/Applications/T3 Code (Beta).app\"}]}]}" ;;
    --caskroom) echo "$SANDBOX/caskroom" ;;'
stub_brew_casks t3-code "$t3_cask"
stub pgrep
receipt '[{"app": ["T3 Code (Alpha).app"]}, {"zap": [{"trash": ["~/.t3/userdata"]}]}]'
assert_exit 0 upgrade_run _upgrade_self_updating_casks upgrade-ai-tools t3-code
assert_file_contains "$STUB_LOG" "brew uninstall --cask --force t3-code"
assert_file_contains "$STUB_LOG" "brew install --cask --adopt t3-code"
assert_file_not_contains "$STUB_LOG" "brew upgrade"
assert_file_not_contains "$STUB_LOG" "pgrep"
for artifacts in '[{"app": ["T3 Code (Alpha).app"]}, {"quit": ["com.t3tools.t3code"]}]' \
    '[{"app": ["T3 Code (Beta).app"]}]'; do
    receipt "$artifacts"
    assert_exit 0 upgrade_run _upgrade_self_updating_casks upgrade-ai-tools t3-code
    assert_file_not_contains "$STUB_LOG" "brew uninstall"
    assert_contains "$RUN_OUTPUT" "Running, so not updated: T3 Code. Quit them and run upgrade-ai-tools again."
done
stub pgrep 'exit 1'
receipt '[{"app": ["T3 Code (Alpha).app"]}]'
stub_brew_casks t3-code "$t3_cask
    \"install \"*) exit 1 ;;"
assert_exit 1 upgrade_run _upgrade_self_updating_casks upgrade-ai-tools t3-code
assert_contains "$RUN_OUTPUT" "Run: brew install --cask --adopt t3-code"

# brew exits 129, 130, or 143 when it catches Ctrl-C
stub brew '[ "$*" != update ] || exit 130'
assert_exit 130 upgrade_run upgrade
assert_file_not_contains "$STUB_LOG" "brew bundle"
assert_file_not_contains "$STUB_LOG" "rustup"
stub_brew_casks "claude codex" '"upgrade --cask --greedy claude") exit 130 ;;'
assert_exit 130 upgrade_run upgrade_ai_tools
assert_file_contains "$STUB_LOG" "brew upgrade --cask --greedy claude"
assert_file_not_contains "$STUB_LOG" "brew upgrade --cask --greedy codex"
assert_file_not_contains "$STUB_LOG" "claude plugin"
test_done
