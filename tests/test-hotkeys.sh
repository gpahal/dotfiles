#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# The hotkeys step: GNOME custom shortcuts that run the Stream Deck's open-in; and lib/gnome.sh's
# list writes, which a failed read mustn't turn into a list that drops your items.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
stub_gsettings
stub gnome-shell 'echo "GNOME Shell 50.1"'
load_script hotkeys/install.sh
as_os ubuntu
MEDIA=org.gnome.settings-daemon.plugins.media-keys
DIR=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
user_shortcut

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The Stream Deck's open-in, which the shortcuts run: bash setup.sh stream-deck"
assert_contains "$RUN_OUTPUT" "missing    Ctrl+Alt+Super+Space opens Claude"

# Without open-in, the shortcuts would do nothing, so the step changes nothing
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "The shortcuts run the Stream Deck's open-in, which isn't installed. Run: bash setup.sh stream-deck"
assert_file_not_contains "$STUB_LOG" "gsettings set"

open_in="$HOME/.local/share/dotfiles/stream-deck/bin/open-in"
mkdir -p "$(dirname "$open_in")"
printf '#!/bin/bash\necho "$OPEN_IN_CALLER|$OPEN_IN_LOG|$*"\n' > "$open_in"
chmod +x "$open_in"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Ctrl+Alt+Super+Space opens Claude"
assert_contains "$RUN_OUTPUT" "Ctrl+Alt+Super+N opens New Tab"
assert_eq "['$DIR/custom0/', '$DIR/dotfiles-claude/', '$DIR/dotfiles-chrome/', '$DIR/dotfiles-t3-code/', '$DIR/dotfiles-terminal/', '$DIR/dotfiles-editor/', '$DIR/dotfiles-chrome-tab/']" \
    "$(gsettings get "$MEDIA" custom-keybindings)" "the shortcut list, with yours kept"

# The command splits as a shell would, and runs open-in with its target
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
gsettings set "$MEDIA.custom-keybinding:$DIR/dotfiles-editor/" binding "'<Control><Alt><Super>x'"
gsettings set "$MEDIA.custom-keybinding:$DIR/custom0/" binding "'<Control><Alt><Super>e'"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Your shortcut at $DIR/custom0/ has Ctrl+Alt+Super+E, so Editor doesn't get it."
assert_eq "'<Control><Alt><Super>e'" "$(gsettings get "$MEDIA.custom-keybinding:$DIR/custom0/" binding)" "your shortcut"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Ctrl+Alt+Super+E for Editor: your shortcut at $DIR/custom0/ has it; change one"

# A failed read writes nothing, rather than a list holding only the new item
paths="$(gsettings get "$MEDIA" custom-keybindings)"
stub gsettings '[ "$1" != get ] || exit 1'
: > "$STUB_LOG"
run gnome_set_keybinding "$DIR/dotfiles-new/" New new "<Super>n"
assert_eq 1 "$RUN_STATUS" "gnome_set_keybinding's status when gsettings can't read"
run gnome_enable_extension new@example.com
assert_eq 1 "$RUN_STATUS" "gnome_enable_extension's status when gsettings can't read"
assert_file_not_contains "$STUB_LOG" "gsettings set"
stub_gsettings
assert_eq "$paths" "$(gsettings get "$MEDIA" custom-keybindings)" "the shortcut list after failed reads"
test_done
