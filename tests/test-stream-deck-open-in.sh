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

# osascript answers the front app's query with ANSWER, and fails with ERROR if set
stub lsappinfo 'case "$1" in
    front) echo "ASN:0x0-0x1:" ;;
    info) echo "    bundleID=\"$FRONT\"" ;;
    find) echo "ASN:0x0-0x2-\"App\":" ;;
esac'
stub osascript 'script="$(cat)"
case "$script" in
    *"make new Finder window"*) echo "  new Finder window" >> "$STUB_LOG" ;;
    *"new surface configuration"*) echo "  new Ghostty $3 at $2" >> "$STUB_LOG" ;;
    *"display notification"*) echo "  notification from $3: $2" >> "$STUB_LOG" ;;
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
export DOTFILES_ZED_CLI="$STUB_DIR/zed-cli" ANSWER="" ERROR=""

# e.g. check files com.apple.finder 0 "open $dir": the stub log less the queries
check() {
    FRONT="$2" assert_exit "$3" bash "$OPEN_IN" "$1"
    assert_eq "$4" "$(grep -vE '^(lsappinfo|osascript|mdls|pbpaste) ' "$STUB_LOG" || true)" "$1 from $2"
}

# While another New Tab runs, from Hammerspoon or Stream Deck, this one does nothing
mkdir "$TMPDIR/dotfiles-new-tab.lock"
echo "$$" > "$TMPDIR/dotfiles-new-tab.lock/pid"
check chrome-tab com.google.Chrome 0 ""
assert_contains "$RUN_OUTPUT" "chrome-tab: another New Tab is still running, so this one did nothing"
rm -r "$TMPDIR/dotfiles-new-tab.lock"

# <front app>|<its answer>|<target>|<the stub log>. A folder that isn't here, such as one over SSH,
# opens a new window. Opening an app would launch it, so Finder shows it instead.
while IFS='|' read -r front answer target expected; do
    ANSWER="$answer" check "$target" "$front" 0 "$expected" < /dev/null
done << EOF
com.mitchellh.ghostty|$dir|files|open $dir
com.mitchellh.ghostty|$dir|terminal|  new Ghostty tab at $dir
com.mitchellh.ghostty|/nonexistent|terminal|  new Ghostty tab at $HOME
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

# T3 Code in front: open-in reads the thread's folder from its state database, querying only an ID
# that's a UUID
if [ -n "$REAL_SQLITE3" ]; then
    export DOTFILES_T3_STATE="$SANDBOX/statev2.sqlite"
    thread=11111111-1111-4111-8111-111111111111
    sqlite3 "$DOTFILES_T3_STATE" "
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, payload_json TEXT NOT NULL);
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT NOT NULL);
        INSERT INTO projection_projects VALUES ('p1', '$HOME/notes');
        INSERT INTO orchestration_v2_projection_threads VALUES ('$thread', 'p1', '{\"worktreePath\": \"$dir\"}');"
    ANSWER="t3code://app/#/env-1/$thread" check files com.t3tools.t3code 0 "open $dir"
    ANSWER="t3code://app/#/env-1/x' OR thread_id != 'x" check files com.t3tools.t3code 0 "  new Finder window"
    assert_contains "$RUN_OUTPUT" "T3 Code isn't showing a thread: t3code://app/#/env-1/x' OR thread_id != 'x"
else
    skip_rest "sqlite3 isn't installed"
fi
test_done
