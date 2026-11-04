#!/bin/bash

# The Stream Deck plugin's open-in: New Tab's lock, then folders from the front app, with stubs
# for lsappinfo, osascript, open, mdls, and the Zed CLI.

# open-in reads T3 Code's database with the real sqlite3, which tests/lib.sh makes a sentinel
REAL_SQLITE3="$(command -v sqlite3 || true)"

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Unlike a stub, it doesn't log
if [ -n "$REAL_SQLITE3" ]; then
    printf '#!/bin/bash\nexec %q "$@"\n' "$REAL_SQLITE3" > "$STUB_DIR/sqlite3"
    chmod +x "$STUB_DIR/sqlite3"
fi

OPEN_IN="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in"
dir="$SANDBOX/project"
file="$dir/main.go"
mkdir -p "$dir" "$HOME/notes" "$SANDBOX/Example.app"
touch "$file" "$HOME/notes/todo.md"

# osascript answers the front app's query with ANSWER, and fails with ERROR if set. Ghostty's
# script, given its mode, the folder, and the input to type, answers GHOSTTY_ANSWER. NOT_RUNNING
# means no app is running.
stub lsappinfo 'case "$1" in
    front) echo "ASN:0x0-0x1:" ;;
    info) echo "    bundleID=\"$FRONT\"" ;;
    find) [ -n "${NOT_RUNNING:-}" ] || echo "ASN:0x0-0x2-\"App\":" ;;
esac'
stub osascript 'script="$(cat)"
case "$script" in
    *"make new Finder window"*) echo "  new Finder window" >> "$STUB_LOG" ;;
    *"new surface configuration"*)
        printf "  Ghostty: %s%s%s\n" "$2" "${3:+ at $3}" "${4:+, typing $(printf %s "$4" | tr -d "\n")}" >> "$STUB_LOG"
        echo "$GHOSTTY_ANSWER"
        ;;
    *"input text (item 1 of argv)"*) echo "  Ghostty: typed $2" >> "$STUB_LOG" ;;
    *"display notification"*) echo "  notification from $3: $2" >> "$STUB_LOG" ;;
    *"make new tab"*) echo "  Chrome tab starting $3, else a new one at $2" >> "$STUB_LOG"; printf "%s\n" "$ANSWER" ;;
    *)
        if [ -n "${ERROR:-}" ]; then echo "$ERROR" >&2; exit 1; fi
        printf "%s\n" "$ANSWER"
        ;;
esac'
stub open
stub zed-cli
# Many lines after the match, as a grep -q reading them would leave mdls writing to a closed pipe
stub mdls 'case "$4" in
    *.app) printf "(\n    \"com.apple.package\",\n"; for i in $(seq 5000); do echo "    \"type.$i\","; done; echo ")" ;;
    *) printf "(\n    \"public.folder\"\n)\n" ;;
esac'
export DOTFILES_ZED_CLI="$STUB_DIR/zed-cli" ANSWER="" ERROR="" GHOSTTY_ANSWER=tab

# e.g. check files com.apple.finder 0 "open $dir": the stub log less the queries, and the blank
# line an argument's newline leaves
# ARG is run's command
check() {
    FRONT="$2" assert_exit "$3" bash "$OPEN_IN" "$1" ${ARG:+"$ARG"}
    assert_eq "$4" "$(grep -vE '^(lsappinfo|osascript|mdls|pbpaste) |^$' "$STUB_LOG" || true)" "$1 from $2"
}

# While another New Tab runs, from Hammerspoon or Stream Deck, this one does nothing
mkdir "$TMPDIR/dotfiles-new-tab.lock"
echo "$$" > "$TMPDIR/dotfiles-new-tab.lock/pid"
check chrome-tab com.google.Chrome 0 ""
assert_contains "$RUN_OUTPUT" "chrome-tab: another New Tab is still running, so this one did nothing"
rm -r "$TMPDIR/dotfiles-new-tab.lock"

# Agenda and Gmail bring their Chrome tab to the front, else open one
ANSWER=found check gmail com.apple.finder 0 "open -b com.google.Chrome
  Chrome tab starting https://mail.google.com/, else a new one at https://mail.google.com/mail/u/0/#inbox"
assert_contains "$RUN_OUTPUT" "gmail: brought the Gmail tab to the front"
ANSWER=opened check agenda com.apple.finder 0 "open -b com.google.Chrome
  Chrome tab starting https://garvitpahal.com/x/agenda, else a new one at https://garvitpahal.com/x/agenda"
assert_contains "$RUN_OUTPUT" "agenda: opened Agenda in a new tab"
ANSWER=found check notion com.apple.finder 0 "open -b com.google.Chrome
  Chrome tab starting https://app.notion.com/, else a new one at https://app.notion.com/"
assert_contains "$RUN_OUTPUT" "notion: brought the Notion tab to the front"

# Terminal with a folder brings Ghostty's tab at it to the front, else opens a tab; from Ghostty,
# it opens another tab. With no folder, it brings Ghostty to the front. Ghostty not running starts
# with its own window, at the folder if there is one.
ANSWER="project — $file" GHOSTTY_ANSWER=found check terminal dev.zed.Zed 0 "  Ghostty: find at $dir"
assert_contains "$RUN_OUTPUT" "terminal: brought Ghostty's tab at $dir to the front"
ANSWER="$dir" GHOSTTY_ANSWER=window check terminal com.apple.finder 0 "  Ghostty: find at $dir"
assert_contains "$RUN_OUTPUT" "terminal: opened a Ghostty window at $dir"
GHOSTTY_ANSWER=switched check terminal com.google.Chrome 0 "  Ghostty: switch"
assert_contains "$RUN_OUTPUT" "terminal: brought Ghostty to the front"
NOT_RUNNING=1 ANSWER="$dir" check terminal com.apple.finder 0 "open -b com.mitchellh.ghostty --args --working-directory=$dir"
NOT_RUNNING=1 check terminal com.google.Chrome 0 "open -b com.mitchellh.ghostty"

# Upgrade types upgrade into a new Ghostty tab, or once a Ghostty it starts has its window
check upgrade com.google.Chrome 0 "  Ghostty: new at $HOME, typing upgrade"
assert_contains "$RUN_OUTPUT" "upgrade: ran upgrade in Ghostty"
NOT_RUNNING=1 check upgrade com.google.Chrome 0 "open -b com.mitchellh.ghostty
  Ghostty: typed upgrade"
# Run types its command, as the ntfy notifier passes an alert's
ARG="ssh -t desktop 'just status'" check run com.google.Chrome 0 "  Ghostty: new at $HOME, typing ssh -t desktop 'just status'"
assert_contains "$RUN_OUTPUT" "run: ran ssh -t desktop 'just status' in Ghostty"
ARG="upsc ups@localhost" NOT_RUNNING=1 check run com.google.Chrome 0 "open -b com.mitchellh.ghostty
  Ghostty: typed upsc ups@localhost"
check run com.google.Chrome 2 ""

# The Claude app's folder is its Code session's: the one whose ID is in the page's address, else
# whose title the window's names, else the one used last that isn't archived. A page that isn't
# Code, such as a chat, has none.
claude="$SANDBOX/claude-code-sessions/account/org"
mkdir -p "$claude"
a=aaaaaaaa-1111-4111-8111-111111111111
b=bbbbbbbb-2222-4222-8222-222222222222
printf '{"sessionId": "local_%s", "cwd": "%s", "originCwd": "/elsewhere", "title": "Fix the login", "lastActivityAt": 1}\n' "$a" "$dir" > "$claude/local_$a.json"
printf '{"sessionId": "local_%s", "originCwd": "%s", "title": "Notes", "lastActivityAt": 5}\n' "$b" "$HOME/notes" > "$claude/local_$b.json"
echo '{"sessionId": "local_c", "cwd": "/srv", "lastActivityAt": 9, "isArchived": true}' > "$claude/local_c.json"
export DOTFILES_CLAUDE_SESSIONS="$SANDBOX/claude-code-sessions"
while IFS='|' read -r url title expected; do
    ANSWER="$url"$'\n'"$title" check files com.anthropic.claudefordesktop 0 "$expected" < /dev/null
done << EOF
https://claude.ai/claude-code-desktop/local_$a|Claude|open $dir
https://claude.ai/code|Fix the login - Claude|open $dir
https://claude.ai/code|Claude|open $HOME/notes
https://claude.ai/new|Fix the login - Claude|  new Finder window
EOF
ANSWER="" check editor com.anthropic.claudefordesktop 0 "open -b dev.zed.Zed $HOME/notes"
assert_contains "$RUN_OUTPUT" "Claude's session folder: $HOME/notes"

# <front app>|<its answer>|<target>|<the stub log>. A folder that isn't here, such as one over SSH,
# opens a new window. Opening an app would launch it, so Finder shows it instead.
while IFS='|' read -r front answer target expected; do
    ANSWER="$answer" check "$target" "$front" 0 "$expected" < /dev/null
done << EOF
com.mitchellh.ghostty|$dir|files|open $dir
com.mitchellh.ghostty|$dir|terminal|  Ghostty: new at $dir
com.mitchellh.ghostty|/nonexistent|terminal|  Ghostty: new at $HOME
com.mitchellh.ghostty|/nonexistent|files|  new Finder window
dev.zed.Zed|project — $file|files|open -R $file
dev.zed.Zed|dotfiles — ~/notes/todo.md|files|open -R $HOME/notes/todo.md
dev.zed.Zed|project|editor|zed-cli --new
com.apple.finder|$dir/|files|open $dir
com.apple.finder|$SANDBOX/Example.app/|files|open -R $SANDBOX/Example.app
EOF

# A missing permission: the new window opens, then a notification says why. Zed with no window
# open fails with -1719 too, which isn't a missing permission.
ERROR="execution error: System Events got an error: osascript is not allowed assistive access. (-25211)" \
    check editor dev.zed.Zed 1 "zed-cli --new
  notification from Stream Deck: Stream Deck lacks a permission: execution error: System Events got an error: osascript is not allowed assistive access. (-25211)"
ERROR="execution error: System Events got an error: Can't get window 1 of process 1. Invalid index. (-1719)" \
    check editor dev.zed.Zed 0 "zed-cli --new"

# T3 Code in front: open-in reads the thread's folder from its state database: the thread whose ID
# ends the page's address, querying only a UUID, then its worktree, else its project's folder. A page
# that isn't a thread has none. With no page read, the window's title or the thread used last picks
# it, leaving out archived ones.
if [ -n "$REAL_SQLITE3" ]; then
    export DOTFILES_T3_STATE="$SANDBOX/statev2.sqlite"
    t1=11111111-1111-4111-8111-111111111111
    t2=22222222-2222-4222-8222-222222222222
    t3=33333333-3333-4333-8333-333333333333
    sqlite3 "$DOTFILES_T3_STATE" "
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
            title TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL);
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT NOT NULL);
        INSERT INTO projection_projects VALUES ('p1', '$HOME/notes');
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('$t1', 'p1', 'Fix the login', '2026-11-01T10:00:00Z', NULL, NULL, '{\"worktreePath\": \"$dir\"}'),
            ('$t2', 'p1', 'Notes', '2026-11-02T10:00:00Z', NULL, NULL, '{}'),
            ('$t3', 'p1', 'Old', '2026-11-03T10:00:00Z', '2026-11-03T11:00:00Z', NULL, '{\"worktreePath\": \"/srv\"}');"
    ANSWER="t3code://app/#/env-1/$t1" check files com.t3tools.t3code 0 "open $dir"
    ANSWER="t3code://app/#/env-1/$t2?panel=diff" check files com.t3tools.t3code 0 "open $HOME/notes"
    ANSWER="t3code://app/#/env-1/x' OR thread_id != 'x" check files com.t3tools.t3code 0 "  new Finder window"
    assert_contains "$RUN_OUTPUT" "T3 Code isn't showing a thread: t3code://app/#/env-1/x' OR thread_id != 'x"
    # No page read: the title, then the thread used last
    stub osascript 'cat > /dev/null; case "$*" in *JavaScript*) printf "\nFix the login — T3 Code\n" ;; esac'
    check files com.t3tools.t3code 0 "open $dir"
    stub osascript 'cat > /dev/null; case "$*" in *JavaScript*) printf "\nT3 Code\n" ;; esac'
    check files com.t3tools.t3code 0 "open $HOME/notes"
else
    skip_rest "sqlite3 isn't installed"
fi
test_done
