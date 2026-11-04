#!/bin/bash

# The Ubuntu Stream Deck's open-in, with busctl standing in for the dotfiles GNOME extension and
# Nautilus, and stubs for systemd-run, pgrep, gdbus, notify-send, and the apps. Ghostty's shells
# are GHOSTTY_SHELLS, child processes in a fake /proc; NO_GHOSTTY means it isn't running.

# open-in reads T3 Code's database with the real sqlite3, which tests/lib.sh makes a sentinel
REAL_SQLITE3="$(command -v sqlite3 || true)"

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &> /dev/null || skip "jq isn't installed"
# Beside the lib it sources, as the stream-deck step installs it
OPEN_IN="$SANDBOX/bin/open-in"
mkdir -p "$SANDBOX/bin"
cp "$REPO_DIR/stream-deck/linux/bin/open-in" "$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in-lib.sh" \
    "$SANDBOX/bin/"
dir="$SANDBOX/my project"
file="$dir/main.go"
mkdir -p "$dir" "$HOME/notes"
touch "$file"

# FRONT is the focused window's JSON; LOCKED and NO_EXTENSION change the extension's answers
stub busctl 'reply() { jq -cn --arg t "$1" --argjson d "$2" "{type: \$t, data: \$d}"; }
case "$*" in
    *" get-property "*OpenWindowsWithLocations) reply "a{sas}" "$NAUTILUS_WINDOWS"; exit ;;
esac
if [ -n "${NO_EXTENSION:-}" ]; then echo "Call failed: Unknown object '"'"'/com/gpahal/Dotfiles'"'"'." >&2; exit 1; fi
case "$7" in
    FocusedWindow) reply s "$(jq -cn --arg s "$FRONT" "[\$s]")" ;;
    ExpectWindow) reply "" "[]" ;;
    ActivateApp | SendKeys) reply b "[true]" ;;
    ModifiersHeld | ClipboardHasText) reply b "[false]" ;;
    IsLocked) reply b "[${LOCKED:-false}]" ;;
esac'
stub systemd-run
stub pgrep 'case "$1" in
    -P) echo "${GHOSTTY_SHELLS:-}" ;;
    *) [ -z "${NO_GHOSTTY:-}" ] || exit 1; echo 4242 ;;
esac'
stub gdbus
stub notify-send
stub zed
stub ghostty
stub nautilus
export NAUTILUS_WINDOWS="{\"/org/gnome/Nautilus/window/2\": [\"file://$HOME/notes\", \"file://${dir// /%20}\", \"trash:///\"],
    \"/org/gnome/Nautilus/window/1\": [\"file:///etc\"]}"

front() {
    FRONT="$(jq -cn --arg c "$1" --arg t "$2" --arg w "${3:-}" '{wmClass: $c, title: $t, gtkObjectPath: $w}')"
    export FRONT
}

# e.g. check files 0 "run nautilus --new-window $dir": the stub log less the queries, with apps
# started as "run <app>" and the extension's calls as "shell <method>"
# ARG is run's command
check() {
    assert_exit "$2" bash "$OPEN_IN" "$1" ${ARG:+"$ARG"}
    sed -e "s|systemd-run --user --quiet --collect -p ExitType=cgroup -- $STUB_DIR/|run |" \
        -e 's|^busctl --user --json=short call org.gnome.Shell /com/gpahal/Dotfiles com.gpahal.Dotfiles |shell |' \
        "$STUB_LOG" > "$SANDBOX/short.log"
    mv "$SANDBOX/short.log" "$STUB_LOG"
    assert_eq "$3" "$(grep -vE '^(pgrep |getent |shell (FocusedWindow|IsLocked|ModifiersHeld|ClipboardHasText)( |$)|busctl --user --json=short get-property)' \
        "$STUB_LOG" || true)" "$1 from ${FRONT}"
}

# <window class>|<title>|<Nautilus window>|<target>|<app id>|<what starts>. Ghostty's title is the
# folder, or "<command> — <folder>" while one runs; Zed's ends with the file; Nautilus's names the
# tab, else its first tab is used. A remote folder, or a title with no folder, opens a new window.
# Ghostty runs with no window here, so Terminal's tab opens one.
while IFS='|' read -r class title window target app started; do
    front "$class" "$title" "$window"
    check "$target" 0 "shell ExpectWindow su $app 10000
$started" < /dev/null
done << EOF
com.mitchellh.ghostty|$dir||files|org.gnome.Nautilus|run nautilus --new-window $dir
com.mitchellh.ghostty|vim main.go — ~/notes||terminal|com.mitchellh.ghostty|ghostty +new-tab --working-directory=$HOME/notes
com.mitchellh.ghostty|/srv/not-here||editor|dev.zed.Zed|run zed --new
com.mitchellh.ghostty|htop||files|org.gnome.Nautilus|run nautilus --new-window $HOME
dev.zed.Zed|my project — $file||terminal|com.mitchellh.ghostty|ghostty +new-tab --working-directory=$dir
dev.zed.Zed|notes — ~/notes||editor|dev.zed.Zed|run zed $HOME/notes
org.gnome.Nautilus|my project|/org/gnome/Nautilus/window/2|terminal|com.mitchellh.ghostty|ghostty +new-tab --working-directory=$dir
google-chrome|Inbox||terminal|com.mitchellh.ghostty|ghostty +new-tab --working-directory=$HOME
org.gnome.Nautilus|Recent|/org/gnome/Nautilus/window/2|editor|dev.zed.Zed|run zed $HOME/notes
org.gnome.Nautilus|Trash|/org/gnome/Nautilus/window/9|editor|dev.zed.Zed|run zed --new
EOF

# Terminal brings the Ghostty tab already at the folder to the front, by its shell's surface ID;
# from Ghostty, or with no tab there, it opens a tab in the window Ghostty used last. With no
# folder, it brings Ghostty to the front.
mkdir -p "$SANDBOX/proc/101" "$SANDBOX/proc/102" "$SANDBOX/proc/103"
printf 'HOME=%s\0GHOSTTY_SURFACE_ID=0x00000000000000aa\0' "$HOME" > "$SANDBOX/proc/101/environ"
ln -s "$HOME/notes" "$SANDBOX/proc/101/cwd"
printf 'GHOSTTY_SURFACE_ID=0xfedcba9876543210\0' > "$SANDBOX/proc/102/environ"
ln -s "$dir" "$SANDBOX/proc/102/cwd"
# Not one of Ghostty's shells
printf 'PATH=/bin\0' > "$SANDBOX/proc/103/environ"
ln -s "$HOME" "$SANDBOX/proc/103/cwd"
export DOTFILES_PROC_DIR="$SANDBOX/proc" GHOSTTY_SHELLS="101 102 103"
front dev.zed.Zed "my project — $file"
check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate present-surface [<uint64 0xfedcba9876543210>] {}"
assert_contains "$RUN_OUTPUT" "terminal: brought Ghostty's tab at $dir to the front"
# shellcheck disable=SC2088 # a literal ~ from the title
front com.mitchellh.ghostty "~/notes"
check terminal 0 "shell ActivateApp ss ghostty_ghostty.desktop com.mitchellh.ghostty
ghostty +new-tab --working-directory=$HOME/notes"
front org.gnome.Nautilus "my project" /org/gnome/Nautilus/window/2
check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate present-surface [<uint64 0xfedcba9876543210>] {}"
front dev.zed.Zed "notes — /srv/not-here/x"
check terminal 0 "shell ActivateApp ss ghostty_ghostty.desktop com.mitchellh.ghostty"
assert_contains "$RUN_OUTPUT" "terminal: brought Ghostty to the front"
NO_GHOSTTY=1 check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty --working-directory=$HOME"
NO_GHOSTTY=1 front dev.zed.Zed "my project — $file"
NO_GHOSTTY=1 check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty --working-directory=$dir"

# Upgrade runs upgrade in a new tab's login shell, interactive so zsh defines it, then the shell
stub getent 'echo "me:x:1000:1000:Me:/home/me:/usr/bin/zsh"'
login_shell=/usr/bin/zsh
check upgrade 0 "shell ActivateApp ss ghostty_ghostty.desktop com.mitchellh.ghostty
ghostty +new-tab --working-directory=$HOME -e $login_shell -i -c upgrade; exec $login_shell -i"
NO_GHOSTTY=1 check upgrade 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty --working-directory=$HOME -e $login_shell -i -c upgrade; exec $login_shell -i"
# Run does the same with its command, as the ntfy notifier passes an alert's
ARG="ssh -t desktop 'just status'" check run 0 "shell ActivateApp ss ghostty_ghostty.desktop com.mitchellh.ghostty
ghostty +new-tab --working-directory=$HOME -e $login_shell -i -c ssh -t desktop 'just status'; exec $login_shell -i"
assert_contains "$RUN_OUTPUT" "run: ran ssh -t desktop 'just status' in Ghostty"
check run 2 ""
unset GHOSTTY_SHELLS

# The Claude app's folder is its Code session's whose title the window's names, else the one used
# last that isn't archived
claude="$SANDBOX/claude-code-sessions/account/org"
mkdir -p "$claude"
printf '{"sessionId": "local_a", "cwd": "%s", "title": "Fix the login", "lastActivityAt": 1}\n' "$dir" > "$claude/local_a.json"
printf '{"sessionId": "local_b", "originCwd": "%s", "title": "Notes", "lastActivityAt": 5}\n' "$HOME/notes" > "$claude/local_b.json"
echo '{"sessionId": "local_c", "cwd": "/srv", "lastActivityAt": 9, "isArchived": true}' > "$claude/local_c.json"
export DOTFILES_CLAUDE_SESSIONS="$SANDBOX/claude-code-sessions"
front com.anthropic.Claude "Fix the login - Claude"
check files 0 "shell ExpectWindow su org.gnome.Nautilus 10000
run nautilus --new-window $dir"
front com.anthropic.Claude "Claude"
check editor 0 "shell ExpectWindow su dev.zed.Zed 10000
run zed $HOME/notes"

# T3 Code's folder is its thread's whose title the window's names, else the one used last that
# isn't archived: its worktree, else its project's folder
if [ -n "$REAL_SQLITE3" ]; then
    printf '#!/bin/bash\nexec %q "$@"\n' "$REAL_SQLITE3" > "$STUB_DIR/sqlite3"
    chmod +x "$STUB_DIR/sqlite3"
    export DOTFILES_T3_STATE="$SANDBOX/statev2.sqlite"
    sqlite3 "$DOTFILES_T3_STATE" "
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
            title TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL);
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT NOT NULL);
        INSERT INTO projection_projects VALUES ('p1', '$HOME/notes');
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('t1', 'p1', 'Fix the login', '2026-11-01T10:00:00Z', NULL, NULL, '{\"worktreePath\": \"$dir\"}'),
            ('t2', 'p1', 'Notes', '2026-11-02T10:00:00Z', NULL, NULL, '{}'),
            ('t3', 'p1', 'Old', '2026-11-03T10:00:00Z', NULL, '2026-11-03T11:00:00Z', '{\"worktreePath\": \"/srv\"}');"
    front com.t3tools.T3Code "Fix the login"
    check files 0 "shell ExpectWindow su org.gnome.Nautilus 10000
run nautilus --new-window $dir"
    front com.t3tools.T3Code "T3 Code"
    check files 0 "shell ExpectWindow su org.gnome.Nautilus 10000
run nautilus --new-window $HOME/notes"
fi

# New Tab, one at a time: a lock whose process is gone, or with no process ID for a minute, is
# taken over; one just made isn't
front google-chrome "New Tab"
lock="$TMPDIR/dotfiles-new-tab-$UID.lock"
(exit 0) &
dead=$!
wait "$dead"
mkdir "$lock"
echo "$dead" > "$lock/pid"
check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t"
mkdir "$lock"
check chrome-tab 0 ""
assert_contains "$RUN_OUTPUT" "chrome-tab: another New Tab is still running, so this one did nothing"
touch -t 202001010000 "$lock"
check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t"
[ ! -e "$lock" ] || fail "the lock outlived its New Tab"

# Gmail, Agenda, and Notion focus their Chrome app window, else launch it
check gmail 0 "shell ActivateApp ss dotfiles-gmail.desktop chrome-mail.google.com__mail_u_0_-Default"
check agenda 0 "shell ActivateApp ss dotfiles-agenda.desktop chrome-garvitpahal.com__x_agenda-Default"
check notion 0 "shell ActivateApp ss dotfiles-notion.desktop chrome-app.notion.com__-Default"

# --- The extension missing, and the screen locked ---
NO_EXTENSION=1 check chrome 1 "notify-send --app-name=Stream Deck Stream Deck The dotfiles GNOME extension isn't running. Log out and back in, or see: bash setup.sh --status stream-deck"
LOCKED=true check editor 1 ""
assert_contains "$RUN_OUTPUT" "editor: the screen is locked, so nothing opened"
test_done
