#!/bin/bash
set -euo pipefail

# The Stream Deck plugin's open-in finds the path the front app shows (a Ghostty tab's folder,
# the file in Zed's window title, Finder's selection) and opens it in Finder, Zed, or Ghostty.
# Ghostty opens a tab when it's in front and a window otherwise. Without a path, such as with
# another app in front or a path that isn't here, it opens a new window: Finder and Ghostty at
# home, Zed empty. A missing permission still opens the window, then fails with a notification.
# Stubs stand in for lsappinfo, osascript, open, and the Zed CLI.

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
# Prints what each app shows, GHOSTTY_CWD, ZED_TITLE, or FINDER_PATH, or fails with ZED_ERROR,
# and logs which script ran
# shellcheck disable=SC2016
stub osascript 'script="$(cat)"
case "$script" in
    *"working directory of focused terminal"*) printf "%s\n" "$GHOSTTY_CWD" ;;
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
    FINDER_PATH="" ZED_ERROR=""

# Run open-in for a target with an app in front, and check its exit status and the lines it
# added to the stub log, other than lsappinfo's and osascript's own
# e.g. check finder com.apple.finder 0 "open $dir"
check() {
    : > "$STUB_LOG"
    FRONT="$2" assert_exit "$3" bash "$OPEN_IN" "$1"
    assert_eq "$4" "$(grep -vE '^(lsappinfo|osascript) ' "$STUB_LOG")" "$1 from $2"
}

# --- Ghostty in front ---
export GHOSTTY_CWD="$dir"
check finder com.mitchellh.ghostty 0 "open $dir"
check editor com.mitchellh.ghostty 0 "open -b dev.zed.Zed $dir"
check terminal com.mitchellh.ghostty 0 "  new Ghostty tab at $dir"
assert_contains "$RUN_OUTPUT" "terminal from com.mitchellh.ghostty: $dir"
# A folder that isn't here, such as one over SSH: a new window
export GHOSTTY_CWD=/nonexistent
check finder com.mitchellh.ghostty 0 "  new Finder window"
check terminal com.mitchellh.ghostty 0 "  new Ghostty tab at $HOME"

# --- Zed in front ---
export ZED_TITLE="project — $file"
check finder dev.zed.Zed 0 "open -R $file"
check editor dev.zed.Zed 0 "open -b dev.zed.Zed $file"
check terminal dev.zed.Zed 0 "  new Ghostty window at $dir"
export ZED_TITLE="dotfiles — ~/notes/todo.md"
check finder dev.zed.Zed 0 "open -R $HOME/notes/todo.md"
# No file open: the title is only the project
export ZED_TITLE="project"
check editor dev.zed.Zed 0 "zed-cli --new"
check terminal dev.zed.Zed 0 "  new Ghostty window at $HOME"

# --- Finder in front ---
export FINDER_PATH="$dir/"
check finder com.apple.finder 0 "open $dir"
check terminal com.apple.finder 0 "  new Ghostty window at $dir"
export FINDER_PATH="$file"
check editor com.apple.finder 0 "open -b dev.zed.Zed $file"
check terminal com.apple.finder 0 "  new Ghostty window at $dir"

# --- Another app in front: new windows ---
check finder com.google.Chrome 0 "  new Finder window"
check editor com.google.Chrome 0 "zed-cli --new"
check terminal com.google.Chrome 0 "  new Ghostty window at $HOME"
# Ghostty isn't running: open starts it at the folder, since telling it to would open a second window
GHOSTTY_RUNNING="" check terminal com.google.Chrome 0 \
    "open -b com.mitchellh.ghostty --args --working-directory=$HOME"

# --- A missing permission: the new window opens, then a notification says why ---
export ZED_ERROR="execution error: System Events got an error: osascript is not allowed assistive access. (-25211)"
check editor dev.zed.Zed 1 "zed-cli --new
  notification: Stream Deck lacks a permission: $ZED_ERROR"
assert_contains "$RUN_OUTPUT" "ERROR $ZED_ERROR"
export ZED_ERROR=""

# A failed open fails, with a notification
stub zed-cli 'exit 1'
check editor com.google.Chrome 1 "zed-cli --new
  notification: Couldn't open a new window. See ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log"

# An unknown target
FRONT=com.apple.finder assert_exit 2 bash "$OPEN_IN" files
assert_contains "$RUN_OUTPUT" "Usage: open-in finder|editor|terminal"
test_done
