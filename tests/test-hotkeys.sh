#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# The hotkeys step: GNOME custom shortcuts that run the Stream Deck's open-in. A gsettings stub keeps
# each key in a file and prints values as gsettings does.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export SANDBOX
# A string prints in single quotes, or double quotes when it holds a single one
stub gsettings 'file="$SANDBOX/gsettings/${2//\//_}.$3"
case "$1" in
    get)
        if [ -e "$file" ]; then cat "$file"
        elif [ "$3" == custom-keybindings ]; then echo "@as []"
        else echo "'"''"'"; fi ;;
    set)
        mkdir -p "$SANDBOX/gsettings"
        case "$3:$4" in
            custom-keybindings:*) printf "%s\n" "$4" > "$file" ;;
            *"'"'"'"*) printf "\"%s\"\n" "$4" > "$file" ;;
            *) printf "'"'"'%s'"'"'\n" "$4" > "$file" ;;
        esac ;;
esac'
load_script hotkeys/install.sh
as_os ubuntu
MEDIA=org.gnome.settings-daemon.plugins.media-keys
DIR=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
# One of yours, on a key the step doesn't use
gsettings set "$MEDIA" custom-keybindings "['$DIR/custom0/']"
gsettings set "$MEDIA.custom-keybinding:$DIR/custom0/" binding "<Super>Return"

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The Stream Deck's open-in, which the shortcuts run: bash setup.sh stream-deck"
assert_contains "$RUN_OUTPUT" "missing    Ctrl+Alt+Super+Space opens Claude"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Ctrl+Alt+Super+Space opens Claude"
assert_contains "$RUN_OUTPUT" "Ctrl+Alt+Super+N opens New Tab"
assert_eq "['$DIR/custom0/', '$DIR/dotfiles-claude/', '$DIR/dotfiles-chrome/', '$DIR/dotfiles-t3-code/', '$DIR/dotfiles-terminal/', '$DIR/dotfiles-editor/', '$DIR/dotfiles-chrome-tab/']" \
    "$(gsettings get "$MEDIA" custom-keybindings)" "the shortcut list, with yours kept"
assert_eq "'<Control><Alt><Super>t'" "$(gsettings get "$MEDIA.custom-keybinding:$DIR/dotfiles-terminal/" binding)" \
    "Terminal's keys"
open_in="$HOME/.local/share/dotfiles/stream-deck/bin/open-in"
assert_eq "\"systemd-cat -t dotfiles-hotkeys env OPEN_IN_CALLER=Hotkeys 'OPEN_IN_LOG=journalctl --user -t dotfiles-hotkeys' /bin/bash '$open_in' chrome-tab\"" \
    "$(gsettings get "$MEDIA.custom-keybinding:$DIR/dotfiles-chrome-tab/" command)" "New Tab's command"

# The command splits as a shell would, and runs open-in with its target
mkdir -p "$(dirname "$open_in")"
printf '#!/bin/bash\necho "$OPEN_IN_CALLER|$OPEN_IN_LOG|$*"\n' > "$open_in"
chmod +x "$open_in"
stub systemd-cat 'shift 2; exec "$@"'
cmd="$(gsettings get "$MEDIA.custom-keybinding:$DIR/dotfiles-claude/" command)"
cmd="${cmd#\"}"
assert_eq "Hotkeys|journalctl --user -t dotfiles-hotkeys|claude" "$(eval "${cmd%\"}")" "running Claude's shortcut"

assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Ctrl+Alt+Super+E opens Editor"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The shortcuts are already set."
assert_file_not_contains "$STUB_LOG" "gsettings set"

# Your own shortcut on the same keys keeps them, and the step says so
gsettings set "$MEDIA.custom-keybinding:$DIR/dotfiles-editor/" binding "<Control><Alt><Super>x"
gsettings set "$MEDIA.custom-keybinding:$DIR/custom0/" binding "<Control><Alt><Super>e"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Your shortcut at $DIR/custom0/ has Ctrl+Alt+Super+E, so Editor doesn't get it."
assert_eq "'<Control><Alt><Super>e'" "$(gsettings get "$MEDIA.custom-keybinding:$DIR/custom0/" binding)" "your shortcut"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Ctrl+Alt+Super+E for Editor: your shortcut at $DIR/custom0/ has it; change one"

test_done
