#!/bin/bash
set -euo pipefail

# The Ubuntu Stream Deck's open-in, with busctl standing in for the dotfiles GNOME extension and
# Nautilus, and stubs for systemd-run, pgrep, notify-send, and the apps.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"
OPEN_IN="$REPO_DIR/stream-deck/linux/bin/open-in"
dir="$SANDBOX/my project"
file="$dir/main.go"
mkdir -p "$dir" "$HOME/notes"
touch "$file"

# FRONT is the focused window's JSON; MISSING_APP, CLIPBOARD, MODIFIERS, LOCKED, and NO_EXTENSION
# change the extension's answers. CHROME_AFTER makes Chrome the focused window after that many
# FocusedWindow calls; CHROME_UNTIL, for that many, and FRONT after. HOLD makes ActivateApp touch
# $SANDBOX/held and wait for $SANDBOX/release.
stub busctl 'reply() { jq -cn --arg t "$1" --argjson d "$2" "{type: \$t, data: \$d}"; }
case "$*" in
    *" get-property "*OpenWindowsWithLocations) reply "a{sas}" "${NAUTILUS_WINDOWS:-{\}}"; exit ;;
    *" ShowItems "*) exit ;;
esac
if [ -n "${NO_EXTENSION:-}" ]; then echo "Call failed: Unknown object '"'"'/com/gpahal/Dotfiles'"'"'." >&2; exit 1; fi
case "$7" in
    FocusedWindow)
        n=$(($(cat "$SANDBOX/focus-calls" 2>/dev/null || echo 0) + 1))
        echo "$n" > "$SANDBOX/focus-calls"
        front="$FRONT"
        [ -z "${CHROME_AFTER:-}" ] || [ "$n" -le "$CHROME_AFTER" ] || front="{\"wmClass\":\"google-chrome\"}"
        [ -z "${CHROME_UNTIL:-}" ] || [ "$n" -gt "$CHROME_UNTIL" ] || front="{\"wmClass\":\"google-chrome\"}"
        reply s "$(jq -cn --arg s "$front" "[\$s]")" ;;
    ActivateApp)
        [ -z "${HOLD:-}" ] || { touch "$SANDBOX/held"; until [ -e "$SANDBOX/release" ]; do sleep 0.01; done; }
        reply b "[$([ "$9" == "${MISSING_APP:-}" ] && echo false || echo true)]" ;;
    ExpectWindow) reply "" "[]" ;;
    ModifiersHeld) reply b "[${MODIFIERS:-false}]" ;;
    SendKeys) reply b "[true]" ;;
    ClipboardHasText) reply b "[${CLIPBOARD:-false}]" ;;
    IsLocked) reply b "[${LOCKED:-false}]" ;;
esac'
stub systemd-run
stub pgrep 'exit 1'
stub notify-send
stub zed
stub ghostty
stub nautilus
export FRONT='{}' NAUTILUS_WINDOWS='{}' SANDBOX

front() {
    FRONT="$(jq -cn --arg c "$1" --arg t "$2" --arg w "${3:-}" '{wmClass: $c, title: $t, gtkObjectPath: $w}')"
}

# e.g. check files 0 "run nautilus --new-window $dir": the stub log less the queries, with apps
# started as "run <app>" and the extension's calls as "shell <method>"
check() {
    : > "$STUB_LOG"
    rm -f "$SANDBOX/focus-calls"
    assert_exit "$2" bash "$OPEN_IN" "$1"
    sed -e "s|systemd-run --user --quiet --collect -p ExitType=cgroup -- $STUB_DIR/|run |" \
        -e 's|^busctl --user --json=short call org.gnome.Shell /com/gpahal/Dotfiles com.gpahal.Dotfiles |shell |' \
        "$STUB_LOG" > "$SANDBOX/short.log"
    mv "$SANDBOX/short.log" "$STUB_LOG"
    assert_stub_log '^(pgrep |shell (FocusedWindow|IsLocked|ModifiersHeld|ClipboardHasText)( |$)|busctl --user --json=short get-property)' \
        "$3" "$1 from ${FRONT}"
}

# --- Ghostty in front: its title is the folder, or "<command> — <folder>" while one runs. A
# running Ghostty opens a window over D-Bus; one that isn't starts at the folder ---
front com.mitchellh.ghostty "${dir/#$HOME/\~}"
check files 0 "shell ExpectWindow su org.gnome.Nautilus 10000
run nautilus --new-window $dir"
check editor 0 "shell ExpectWindow su dev.zed.Zed 10000
run zed $dir"
check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty --working-directory=$dir"
assert_contains "$RUN_OUTPUT" "terminal from com.mitchellh.ghostty: $dir"
stub pgrep 'echo 4242'
front com.mitchellh.ghostty "vim main.go — ~/notes"
check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty +new-window --working-directory=$HOME/notes"
front com.mitchellh.ghostty "~"
check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty +new-window --working-directory=$HOME"
# A remote shell's folder, or a title with no folder, opens a new window
front com.mitchellh.ghostty "/srv/not-here"
check editor 0 "shell ExpectWindow su dev.zed.Zed 10000
run zed --new"
front com.mitchellh.ghostty "htop"
check files 0 "shell ExpectWindow su org.gnome.Nautilus 10000
run nautilus --new-window $HOME"
assert_contains "$RUN_OUTPUT" "Ghostty's title doesn't end with its folder: htop"

# --- Zed in front: its title ends with the file ---
front dev.zed.Zed "my project — $file"
check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty +new-window --working-directory=$dir"
check files 0 "shell ExpectWindow su org.gnome.Nautilus 10000
busctl --user call org.freedesktop.FileManager1 /org/freedesktop/FileManager1 org.freedesktop.FileManager1 ShowItems ass 1 file://${dir// /%20}/main.go "
front dev.zed.Zed "notes — ~/notes"
check editor 0 "shell ExpectWindow su dev.zed.Zed 10000
run zed $HOME/notes"

# --- Nautilus in front: the tab named like the window, else its first tab ---
export NAUTILUS_WINDOWS="{\"/org/gnome/Nautilus/window/2\": [\"file://$HOME/notes\", \"file://${dir// /%20}\", \"trash:///\"],
    \"/org/gnome/Nautilus/window/1\": [\"file:///etc\"]}"
front org.gnome.Nautilus "my project" /org/gnome/Nautilus/window/2
check terminal 0 "shell ExpectWindow su com.mitchellh.ghostty 10000
run ghostty +new-window --working-directory=$dir"
front org.gnome.Nautilus "Recent" /org/gnome/Nautilus/window/2
check editor 0 "shell ExpectWindow su dev.zed.Zed 10000
run zed $HOME/notes"
front org.gnome.Nautilus "Trash" /org/gnome/Nautilus/window/9
check editor 0 "shell ExpectWindow su dev.zed.Zed 10000
run zed --new"

# --- Apps: focused or launched by the extension ---
front google-chrome "New Tab"
MISSING_APP=com.anthropic.Claude.desktop check claude 1 "shell ActivateApp ss com.anthropic.Claude.desktop com.anthropic.Claude
notify-send --app-name=Stream Deck Stream Deck Couldn't open Claude. Is it installed?"

# --- New Tab: Ctrl+T once Chrome is in front, then the clipboard pasted and selected ---
check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab"
CLIPBOARD=true check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t
shell SendKeys s ctrl+v
shell SendKeys s ctrl+a"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab with the clipboard pasted"
front com.mitchellh.ghostty "~"
CHROME_AFTER=3 CLIPBOARD=true check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t
shell SendKeys s ctrl+v
shell SendKeys s ctrl+a"
# Chrome in front for the Ctrl+T, then another window before the paste
CHROME_UNTIL=2 CLIPBOARD=true check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t"
assert_contains "$RUN_OUTPUT" "another window came to the front before the paste"
front google-chrome "New Tab"
DOTFILES_NEW_TAB_WAIT=0 MODIFIERS=true check chrome-tab 1 "shell ActivateApp ss google-chrome.desktop google-chrome
notify-send --app-name=Stream Deck Stream Deck Couldn't open a new Chrome tab. See journalctl --user -u dotfiles-stream-deck"
assert_contains "$RUN_OUTPUT" "modifier keys were still held"

# --- New Tab one at a time: another while the first runs does nothing ---
lock="$TMPDIR/dotfiles-new-tab-$UID.lock"
HOLD=1 bash "$OPEN_IN" chrome-tab > "$SANDBOX/first.out" 2>&1 &
first=$!
wait_for test -e "$SANDBOX/held" || true
[ -e "$SANDBOX/held" ] || fail "the first New Tab didn't reach ActivateApp"
check chrome-tab 0 ""
assert_contains "$RUN_OUTPUT" "chrome-tab: another New Tab is still running, so this one did nothing"
touch "$SANDBOX/release"
wait "$first" || fail "the first New Tab failed: $(cat "$SANDBOX/first.out")"
assert_file_contains "$SANDBOX/first.out" "chrome-tab: opened a new tab"
[ ! -e "$lock" ] || fail "the lock outlived its New Tab"
# A lock whose process is gone, or with no process ID for a minute, is taken over; one just made
# isn't
(exit 0) &
dead=$!
wait "$dead"
mkdir "$lock"
echo "$dead" > "$lock/pid"
check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t"
mkdir "$lock"
check chrome-tab 0 ""
touch -t 202001010000 "$lock"
check chrome-tab 0 "shell ActivateApp ss google-chrome.desktop google-chrome
shell SendKeys s ctrl+t"

# --- The extension missing, and the screen locked ---
front google-chrome "New Tab"
NO_EXTENSION=1 check chrome 1 "notify-send --app-name=Stream Deck Stream Deck The dotfiles GNOME extension isn't running. Log out and back in, or see: bash setup.sh --status stream-deck"
assert_contains "$RUN_OUTPUT" "Unknown object '/com/gpahal/Dotfiles'"
LOCKED=true check editor 1 ""
assert_contains "$RUN_OUTPUT" "editor: the screen is locked, so nothing opened"

test_done
