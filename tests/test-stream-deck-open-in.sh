#!/bin/bash
set -euo pipefail
# os: macos

# The Stream Deck plugin's open-in finds the path the front app shows (a Ghostty tab's folder,
# the file in Zed's window title, Finder's selection, the folder of T3 Code's thread) and opens it
# in Finder, Zed, or Ghostty.
# Ghostty opens a tab when it's in front and a window otherwise. Without a path, such as with
# another app in front or a path that isn't here, it opens a new window: Finder and Ghostty at
# home, Zed empty. A missing permission still opens the window, then fails with a notification.
# Stubs stand in for lsappinfo, osascript, open, and the Zed CLI, and a database with T3 Code's
# tables for its state.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
OPEN_IN="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in"
dir="$SANDBOX/project"
file="$dir/main.go"
mkdir -p "$dir" "$HOME/notes"
touch "$file" "$HOME/notes/todo.md"

# FRONT is the front app's bundle ID; GHOSTTY_RUNNING, when set, makes Ghostty running
# shellcheck disable=SC2016 # stub bodies, expanded when they run
stub lsappinfo 'case "$1" in
    front) echo "ASN:0x0-0x1:" ;;
    info) echo "    bundleID=\"$FRONT\"" ;;
    find) [ -z "${GHOSTTY_RUNNING:-}" ] || [ "$2" != bundleid=com.mitchellh.ghostty ] || echo "ASN:0x0-0x2-\"Ghostty\":" ;;
esac'
# Prints what each app shows, GHOSTTY_CWD, ZED_TITLE, FINDER_PATH, or T3_URL, or fails with ZED_ERROR,
# and logs which script ran
# shellcheck disable=SC2016
stub osascript 'script="$(cat)"
case "$script" in
    *"working directory of focused terminal"*) printf "%s\n" "$GHOSTTY_CWD" ;;
    *AXURL*) printf "%s\n" "$T3_URL" ;;
    *"System Events"*)
        if [ -n "${ZED_ERROR:-}" ]; then echo "$ZED_ERROR" >&2; exit 1; fi
        printf "%s\n" "$ZED_TITLE"
        ;;
    *"set selected to selection"*) printf "%s\n" "$FINDER_PATH" ;;
    *"make new Finder window"*) echo "  new Finder window" >> "$STUB_LOG" ;;
    *"new surface configuration"*) echo "  new Ghostty $3 at $2" >> "$STUB_LOG" ;;
    *"display notification"*) echo "  notification: $2" >> "$STUB_LOG" ;;
esac'
stub open
stub zed-cli
export DOTFILES_ZED_CLI="$STUB_DIR/zed-cli" GHOSTTY_RUNNING=1 GHOSTTY_CWD="" ZED_TITLE="" \
    FINDER_PATH="" ZED_ERROR="" T3_URL=""

# T3 Code's state: one thread in a worktree, one in its project's folder, and one in a project
# that's gone
command -v sqlite3 &> /dev/null || skip "sqlite3 isn't installed"
export DOTFILES_T3_STATE="$SANDBOX/statev2.sqlite"
thread_wt=11111111-1111-4111-8111-111111111111
thread_project=22222222-2222-4222-8222-222222222222
thread_gone=33333333-3333-4333-8333-333333333333
sqlite3 "$DOTFILES_T3_STATE" "
    CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, payload_json TEXT NOT NULL);
    CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT NOT NULL);
    INSERT INTO projection_projects VALUES ('p1', '$HOME/notes');
    INSERT INTO orchestration_v2_projection_threads VALUES
        ('$thread_wt', 'p1', '{\"worktreePath\": \"$dir\"}'),
        ('$thread_project', 'p1', '{\"worktreePath\": null}'),
        ('$thread_gone', 'p2', '{}');"

# Run open-in for a target with an app in front, and check its exit status and the lines it
# added to the stub log, other than lsappinfo's and osascript's own
# e.g. check files com.apple.finder 0 "open $dir"
check() {
    : > "$STUB_LOG"
    FRONT="$2" assert_exit "$3" bash "$OPEN_IN" "$1"
    assert_eq "$4" "$(grep -vE '^(lsappinfo|osascript) ' "$STUB_LOG")" "$1 from $2"
}

# --- Ghostty in front ---
export GHOSTTY_CWD="$dir"
check files com.mitchellh.ghostty 0 "open $dir"
check editor com.mitchellh.ghostty 0 "open -b dev.zed.Zed $dir"
check terminal com.mitchellh.ghostty 0 "  new Ghostty tab at $dir"
assert_contains "$RUN_OUTPUT" "terminal from com.mitchellh.ghostty: $dir"
# A folder that isn't here, such as one over SSH: a new window
export GHOSTTY_CWD=/nonexistent
check files com.mitchellh.ghostty 0 "  new Finder window"
check terminal com.mitchellh.ghostty 0 "  new Ghostty tab at $HOME"
# Ghostty reports no folder, as when the hostname breaks its OSC 7 report: the log says where to look
export GHOSTTY_CWD=""
check files com.mitchellh.ghostty 0 "  new Finder window"
assert_contains "$RUN_OUTPUT" "Ghostty doesn't know the tab's folder. Run: bash setup.sh --status macos"

# --- Zed in front ---
export ZED_TITLE="project — $file"
check files dev.zed.Zed 0 "open -R $file"
check editor dev.zed.Zed 0 "open -b dev.zed.Zed $file"
check terminal dev.zed.Zed 0 "  new Ghostty window at $dir"
export ZED_TITLE="dotfiles — ~/notes/todo.md"
check files dev.zed.Zed 0 "open -R $HOME/notes/todo.md"
# No file open: the title is only the project
export ZED_TITLE="project"
check editor dev.zed.Zed 0 "zed-cli --new"
check terminal dev.zed.Zed 0 "  new Ghostty window at $HOME"

# --- Finder in front ---
export FINDER_PATH="$dir/"
check files com.apple.finder 0 "open $dir"
check terminal com.apple.finder 0 "  new Ghostty window at $dir"
export FINDER_PATH="$file"
check editor com.apple.finder 0 "open -b dev.zed.Zed $file"
check terminal com.apple.finder 0 "  new Ghostty window at $dir"

# --- T3 Code in front ---
export T3_URL="t3code://app/#/env-1/$thread_wt"
check files com.t3tools.t3code 0 "open $dir"
check editor com.t3tools.t3code 0 "open -b dev.zed.Zed $dir"
check terminal com.t3tools.t3code 0 "  new Ghostty window at $dir"
# No worktree: the project's folder
export T3_URL="t3code://app/#/env-1/$thread_project"
check editor com.t3tools.t3code 0 "open -b dev.zed.Zed $HOME/notes"
# A thread with no folder known, or a page that isn't a thread: a new window
export T3_URL="t3code://app/#/env-1/$thread_gone"
check files com.t3tools.t3code 0 "  new Finder window"
export T3_URL="t3code://app/#/settings"
check editor com.t3tools.t3code 0 "zed-cli --new"
assert_contains "$RUN_OUTPUT" "T3 Code isn't showing a thread: $T3_URL"
# The database can't be read: logged, and a new window
DOTFILES_T3_STATE="$SANDBOX/missing/statev2.sqlite" T3_URL="t3code://app/#/env-1/$thread_wt" \
    check terminal com.t3tools.t3code 0 "  new Ghostty window at $HOME"
assert_contains "$RUN_OUTPUT" "ERROR couldn't read thread $thread_wt's folder"
export T3_URL=""

# --- Another app in front: new windows ---
# Ghostty isn't running: open starts it at the folder, since telling it to would open a second window
GHOSTTY_RUNNING="" check terminal com.google.Chrome 0 \
    "open -b com.mitchellh.ghostty --args --working-directory=$HOME"

# --- A missing permission: the new window opens, then a notification says why ---
export ZED_ERROR="execution error: System Events got an error: osascript is not allowed assistive access. (-25211)"
check editor dev.zed.Zed 1 "zed-cli --new
  notification: Stream Deck lacks a permission: $ZED_ERROR"
assert_contains "$RUN_OUTPUT" "ERROR $ZED_ERROR"
# Zed with no window open fails with -1719 too, which isn't a missing permission
export ZED_ERROR="execution error: System Events got an error: Can't get window 1 of process 1. Invalid index. (-1719)"
check editor dev.zed.Zed 0 "zed-cli --new"
export ZED_ERROR=""

# A failed open fails, with a notification
stub zed-cli 'exit 1'
check editor com.google.Chrome 1 "zed-cli --new
  notification: Couldn't open a new window. See ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log"
test_done
