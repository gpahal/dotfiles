#!/bin/bash
# shellcheck disable=SC2329

# The gnome step: GNOME settings that match the macos step, and gnome-sushi. stub_gsettings starts
# from Ubuntu's defaults. Also lib/gnome.sh's shortcut clashes and extension states.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

stub_gsettings
default() { printf '%s\n' "$3" > "$SANDBOX/gsettings/$1.$2"; }
default org.gnome.desktop.peripherals.keyboard delay "uint32 500"
default org.gnome.desktop.peripherals.keyboard repeat-interval "uint32 30"
default org.gtk.Settings.FileChooser show-hidden false
default org.gtk.gtk4.Settings.FileChooser show-hidden false
default org.gnome.nautilus.preferences default-folder-viewer "'icon-view'"
default org.gnome.shell.extensions.dash-to-dock dock-fixed true
default org.gnome.shell.extensions.dash-to-dock autohide true
default org.gnome.shell.extensions.dash-to-dock intellihide true
stub gnome-shell
stub_apt_packages
stub_sudo_exec
load_script gnome/install.sh
as_os ubuntu
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Keys repeat after 225 ms (org.gnome.desktop.peripherals.keyboard delay is uint32 500, not uint32 225)"
assert_contains "$RUN_OUTPUT" "ok         Keys repeat every 30 ms"

# Declining sudo still sets the GNOME settings, which need none
answer no
assert_exit 0 main
assert_eq "uint32 225" "$(gsettings get org.gnome.desktop.peripherals.keyboard delay)" "the key repeat delay"
assert_eq "true" "$(gsettings get org.gtk.Settings.FileChooser show-hidden)" "hidden files in GTK 3 file choosers"
assert_eq "true" "$(gsettings get org.gtk.gtk4.Settings.FileChooser show-hidden)" "hidden files in Files"
assert_eq "'list-view'" "$(gsettings get org.gnome.nautilus.preferences default-folder-viewer)" "Files' view"
assert_eq "false" "$(gsettings get org.gnome.shell.extensions.dash-to-dock dock-fixed)" "the dock pinned open"
assert_eq "false" "$(gsettings get org.gnome.shell.extensions.dash-to-dock intellihide)" "the dock's intellihide"
assert_file_not_contains "$STUB_LOG" "gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval"
assert_file_not_contains "$STUB_LOG" "gsettings set org.gnome.shell.extensions.dash-to-dock autohide"
assert_file_not_contains "$STUB_LOG" "apt-get"

# Accepting installs gnome-sushi; then a re-run changes nothing
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "install -y gnome-sushi"
assert_exit 0 main --status
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "gsettings set"
assert_file_not_contains "$STUB_LOG" "sudo"

# Without Ubuntu's dock, its settings are skipped, not failed
echo org.gnome.shell.extensions.dash-to-dock > "$SANDBOX/gsettings/no-schema"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Dock hides: GNOME has no org.gnome.shell.extensions.dash-to-dock autohide here"
assert_exit 0 main
rm "$SANDBOX/gsettings/no-schema"

# --- lib/gnome.sh ---
# shellcheck source=../lib/gnome.sh
source "$REPO_DIR/lib/gnome.sh"
# One spelling per accelerator: modifier aliases in any case and order, and a letter in either case
while IFS='|' read -r accel want; do
    assert_eq "$want" "$(gnome_accelerator "$accel")" "the spelling of $accel"
done << 'EOF'
<Ctrl><Super>t|<control><super>t
<Super><Control>T|<control><super>t
<Mod1><SHIFT>a|<alt><shift>a
<Primary><primary>x|<control>x
<Hyper><Mod4>F1|<hyper><mod4>F1
<Shft>space|<shift>space
<Release><ALT>Q|<alt><release>q
<Meta><Ctl><Super><Shift><Hyper><Alt>1|<alt><control><hyper><meta><shift><super>1
A|a
z|z
EOF
# Another custom shortcut on the same keys clashes however its binding is spelled
user_shortcut
gsettings set "$GNOME_MEDIA_KEYS.custom-keybinding:$GNOME_KEYBINDING_DIR/custom0/" binding "'<Ctrl><Super>t'"
own="$GNOME_KEYBINDING_DIR/dotfiles/"
for binding in "<Ctrl><Super>t" "<Super><Control>T" "<super><primary>t"; do
    gnome_keybinding_clash "$binding" "$own" || fail "no clash with $binding"
    assert_eq "$GNOME_KEYBINDING_DIR/custom0/" "$GNOME_KEYBINDING_CLASH" "the clash with $binding"
done
for binding in "<Super>t" "<Shift><Control><Super>t" "<Ctrl><Super>y"; do
    assert_exit 1 gnome_keybinding_clash "$binding" "$own"
done
assert_exit 1 gnome_keybinding_clash "<Super><Control>t" "$GNOME_KEYBINDING_DIR/custom0/"
# The map of bindings is kept through a run, so a change must refresh it
"$GNOME_KEYBINDING_MAP_FILLED" || fail "gnome_keybinding_clash didn't keep the map of bindings"
gnome_set_keybinding "$own" Own own "<Super>y"
gnome_keybinding_clash "<Super>y" "$GNOME_KEYBINDING_DIR/custom0/" || fail "no clash with a shortcut set in this run"
assert_eq "$own" "$GNOME_KEYBINDING_CLASH" "the clash with a shortcut set in this run"

# An enabled extension's state, as GNOME Shell reports it
extension_states() {
    local dir="$SANDBOX/extension"
    stub_gnome_session "$SANDBOX/session"
    mkdir -p "$dir"
    echo "{}" > "$dir/metadata.json"
    gsettings set org.gnome.shell enabled-extensions "['x@dotfiles']"
    loaded() {
        status_gnome_extension x@dotfiles "$dir" "GNOME extension"
        status_result
    }
    SHELL_STATE=1 assert_exit 0 loaded
    assert_contains "$RUN_OUTPUT" "ok         GNOME extension loaded"
    SHELL_STATE=unknown assert_exit 3 loaded
    assert_contains "$RUN_OUTPUT" "missing    GNOME extension loaded: log out and back in"
    SHELL_STATE=4 assert_exit 3 loaded
    assert_contains "$RUN_OUTPUT" "missing    GNOME extension loaded: it doesn't list this GNOME version"
    SHELL_STATE=3 SHELL_ERROR="TypeError: x is undefined" assert_exit 3 loaded
    assert_contains "$RUN_OUTPUT" "missing    GNOME extension loaded: it failed: TypeError: x is undefined"
    # Over SSH with no desktop login
    assert_exit 0 loaded
    assert_contains "$RUN_OUTPUT" "unverified GNOME extension loaded"
}
if command -v jq &> /dev/null; then
    subtest extension_states
else
    skip_rest "jq isn't installed, so GNOME Shell's extension states can't be read"
fi

# A failed set fails the step, and it carries on with the rest
gsettings set org.gnome.desktop.peripherals.keyboard delay "uint32 500"
gsettings set org.gnome.nautilus.preferences default-folder-viewer "'icon-view'"
stub gsettings 'file="$SANDBOX/gsettings/$2.$3"
case "$1" in
    get) cat "$file" ;;
    set) [ "$3" != delay ] || exit 1; printf "%s\n" "$4" > "$file" ;;
esac'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't set org.gnome.desktop.peripherals.keyboard delay"
assert_eq "'list-view'" "$(gsettings get org.gnome.nautilus.preferences default-folder-viewer)" "Files' view after a failed set"

# Ubuntu Server: no GNOME, nothing to do
hide gnome-shell
assert_exit 0 main
cp "$STUB_LOG" "$SANDBOX/both.log"
assert_exit 0 main --status
cat "$STUB_LOG" >> "$SANDBOX/both.log"
assert_contains "$RUN_OUTPUT" "skipped    GNOME settings: no GNOME desktop"
assert_eq "" "$(cat "$SANDBOX/both.log")" "commands the step ran without GNOME"
test_done
