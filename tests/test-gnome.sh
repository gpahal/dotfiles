#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# The gnome step: GNOME settings that match the macos step, and gnome-sushi. A gsettings stub keeps
# each key in a file, starting from Ubuntu's defaults; a schema listed in $SANDBOX/no-schema is
# missing, as the dock's is on GNOME without Ubuntu's.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export SANDBOX
mkdir -p "$SANDBOX/gsettings"
default() { printf '%s\n' "$3" > "$SANDBOX/gsettings/$1.$2"; }
default org.gnome.desktop.peripherals.keyboard delay "uint32 500"
default org.gnome.desktop.peripherals.keyboard repeat-interval "uint32 30"
default org.gtk.Settings.FileChooser show-hidden false
default org.gtk.gtk4.Settings.FileChooser show-hidden false
default org.gnome.nautilus.preferences default-folder-viewer "'icon-view'"
default org.gnome.shell.extensions.dash-to-dock dock-fixed true
default org.gnome.shell.extensions.dash-to-dock autohide true
default org.gnome.shell.extensions.dash-to-dock intellihide true
# Values print as gsettings prints them: a typed number, a bool, or a quoted string
stub gsettings 'file="$SANDBOX/gsettings/$2.$3"
! grep -qxF "$2" "$SANDBOX/no-schema" 2> /dev/null || { echo "No such schema “$2”" >&2; exit 1; }
case "$1" in
    get) cat "$file" ;;
    set) case "$(cat "$file")" in
            uint32*) printf "uint32 %s\n" "${4#uint32 }" > "$file" ;;
            *) printf "%s\n" "$4" > "$file" ;;
        esac ;;
esac'
stub gnome-shell
stub dpkg-query '[ ! -e "$SANDBOX/sushi" ] || echo "install ok installed"'
stub apt-get '[ "${!#}" != gnome-sushi ] || touch "$SANDBOX/sushi"'
stub_sudo_exec
load_script gnome/install.sh
as_os ubuntu
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Keys repeat after 225 ms (org.gnome.desktop.peripherals.keyboard delay is uint32 500, not uint32 225)"
assert_contains "$RUN_OUTPUT" "ok         Keys repeat every 30 ms (org.gnome.desktop.peripherals.keyboard repeat-interval)"
assert_contains "$RUN_OUTPUT" "missing    Files opens folders in list view"
assert_contains "$RUN_OUTPUT" "missing    Quick Look: gnome-sushi, so Space in Files previews the selected file"

# Declining sudo still sets the GNOME settings, which need none
answer no
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Keys repeat after 225 ms (org.gnome.desktop.peripherals.keyboard delay = uint32 225)"
assert_contains "$RUN_OUTPUT" "Install gnome-sushi, so Space in Files previews the selected file"
assert_eq "uint32 225" "$(gsettings get org.gnome.desktop.peripherals.keyboard delay)" "the key repeat delay"
assert_eq "true" "$(gsettings get org.gtk.Settings.FileChooser show-hidden)" "hidden files in Files"
assert_eq "true" "$(gsettings get org.gtk.gtk4.Settings.FileChooser show-hidden)" "hidden files in GTK 4 file choosers"
assert_eq "'list-view'" "$(gsettings get org.gnome.nautilus.preferences default-folder-viewer)" "Files' view"
assert_eq "false" "$(gsettings get org.gnome.shell.extensions.dash-to-dock dock-fixed)" "the dock pinned open"
assert_eq "false" "$(gsettings get org.gnome.shell.extensions.dash-to-dock intellihide)" "the dock's intellihide"
assert_file_not_contains "$STUB_LOG" "gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval"
assert_file_not_contains "$STUB_LOG" "gsettings set org.gnome.shell.extensions.dash-to-dock autohide"
assert_file_not_contains "$STUB_LOG" "apt-get"

# Accepting installs gnome-sushi; then a re-run changes nothing
answer yes
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The settings are already set."
assert_file_contains "$STUB_LOG" "install -y gnome-sushi"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Quick Look: gnome-sushi"
assert_contains "$RUN_OUTPUT" "ok         Dock hides even with no window under it (org.gnome.shell.extensions.dash-to-dock intellihide)"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "gsettings set"
assert_file_not_contains "$STUB_LOG" "sudo"

# A setting you change back shows, and the next run sets it again
gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed true
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Dock not pinned open (org.gnome.shell.extensions.dash-to-dock dock-fixed is true, not false)"
assert_exit 0 main
assert_eq "false" "$(gsettings get org.gnome.shell.extensions.dash-to-dock dock-fixed)" "the dock after a re-run"

# Without Ubuntu's dock, its settings are skipped, not failed
echo org.gnome.shell.extensions.dash-to-dock > "$SANDBOX/no-schema"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Dock hides: GNOME has no org.gnome.shell.extensions.dash-to-dock autohide here"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "GNOME has no org.gnome.shell.extensions.dash-to-dock dock-fixed here, so skipped: Dock not pinned open."

# A failed set fails the step, and it carries on with the rest
rm "$SANDBOX/no-schema"
gsettings set org.gnome.desktop.peripherals.keyboard delay 500
gsettings set org.gnome.nautilus.preferences default-folder-viewer "'icon-view'"
stub gsettings 'file="$SANDBOX/gsettings/$2.$3"
case "$1" in
    get) cat "$file" ;;
    set) [ "$3" != delay ] || exit 1; printf "%s\n" "$4" > "$file" ;;
esac'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't set org.gnome.desktop.peripherals.keyboard delay to uint32 225."
assert_eq "'list-view'" "$(gsettings get org.gnome.nautilus.preferences default-folder-viewer)" "Files' view after a failed set"

hide gsettings
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "gsettings isn't installed"

# Ubuntu Server: no GNOME, nothing to do
hide gnome-shell
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "No GNOME desktop, so skipped."
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    GNOME settings: no GNOME desktop"
assert_eq "" "$(cat "$STUB_LOG")" "commands the step ran without GNOME"

as_os macos
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "gnome: skipped, Ubuntu only" "$RUN_OUTPUT" "the step on macOS"
assert_eq "" "$(cat "$STUB_LOG")" "commands the skipped step ran"

test_done
