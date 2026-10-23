#!/bin/bash
set -euo pipefail

# The Ubuntu Stream Deck's open-in, with busctl standing in for the dotfiles GNOME extension and
# Nautilus, and stubs for systemd-run, pgrep, notify-send, and the apps.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
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
stub pgrep 'echo 4242'
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
check() {
    : > "$STUB_LOG"
    assert_exit "$2" bash "$OPEN_IN" "$1"
    sed -e "s|systemd-run --user --quiet --collect -p ExitType=cgroup -- $STUB_DIR/|run |" \
        -e 's|^busctl --user --json=short call org.gnome.Shell /com/gpahal/Dotfiles com.gpahal.Dotfiles |shell |' \
        "$STUB_LOG" > "$SANDBOX/short.log"
    mv "$SANDBOX/short.log" "$STUB_LOG"
    assert_eq "$3" "$(grep -vE '^(pgrep |shell (FocusedWindow|IsLocked|ModifiersHeld|ClipboardHasText)( |$)|busctl --user --json=short get-property)' \
        "$STUB_LOG" || true)" "$1 from ${FRONT}"
}

# <window class>|<title>|<Nautilus window>|<target>|<app id>|<what starts>. Ghostty's title is the
# folder, or "<command> — <folder>" while one runs; Zed's ends with the file; Nautilus's names the
# tab, else its first tab is used. A remote folder, or a title with no folder, opens a new window.
while IFS='|' read -r class title window target app started; do
    front "$class" "$title" "$window"
    check "$target" 0 "shell ExpectWindow su $app 10000
$started" < /dev/null
done << EOF
com.mitchellh.ghostty|$dir||files|org.gnome.Nautilus|run nautilus --new-window $dir
com.mitchellh.ghostty|vim main.go — ~/notes||terminal|com.mitchellh.ghostty|run ghostty +new-window --working-directory=$HOME/notes
com.mitchellh.ghostty|/srv/not-here||editor|dev.zed.Zed|run zed --new
com.mitchellh.ghostty|htop||files|org.gnome.Nautilus|run nautilus --new-window $HOME
dev.zed.Zed|my project — $file||terminal|com.mitchellh.ghostty|run ghostty +new-window --working-directory=$dir
dev.zed.Zed|notes — ~/notes||editor|dev.zed.Zed|run zed $HOME/notes
org.gnome.Nautilus|my project|/org/gnome/Nautilus/window/2|terminal|com.mitchellh.ghostty|run ghostty +new-window --working-directory=$dir
org.gnome.Nautilus|Recent|/org/gnome/Nautilus/window/2|editor|dev.zed.Zed|run zed $HOME/notes
org.gnome.Nautilus|Trash|/org/gnome/Nautilus/window/9|editor|dev.zed.Zed|run zed --new
EOF

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

# --- The extension missing, and the screen locked ---
NO_EXTENSION=1 check chrome 1 "notify-send --app-name=Stream Deck Stream Deck The dotfiles GNOME extension isn't running. Log out and back in, or see: bash setup.sh --status stream-deck"
LOCKED=true check editor 1 ""
assert_contains "$RUN_OUTPUT" "editor: the screen is locked, so nothing opened"
test_done
