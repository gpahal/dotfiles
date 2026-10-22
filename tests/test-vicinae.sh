#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# The vicinae step: Vicinae from its installer into ~/.local, its GNOME extension from
# extensions.gnome.org, its user service, and Super+Space; and update_vicinae, which upgrade runs.
# A fake installer writes what the real one does for a prefix under HOME. A gsettings stub keeps
# each key in a file and prints values as gsettings does.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"
STATE="$SANDBOX/state"
export SANDBOX STATE
mkdir -p "$STATE" "$SANDBOX/gsettings"
# Lists print as stored; a string in single quotes, or double quotes when it holds a single one
stub gsettings 'file="$SANDBOX/gsettings/${2//\//_}.$3"
case "$1" in
    get)
        if [ -e "$file" ]; then cat "$file"
        else case "$3" in
            enabled-extensions | custom-keybindings) echo "@as []" ;;
            switch-input-source) echo "['"'"'<Super>space'"'"', '"'"'XF86Keyboard'"'"']" ;;
            *) echo "'"''"'" ;;
        esac; fi ;;
    set)
        case "$4" in
            "["* | "@as"*) printf "%s\n" "$4" > "$file" ;;
            *"'"'"'"*) printf "\"%s\"\n" "$4" > "$file" ;;
            *) printf "'"'"'%s'"'"'\n" "$4" > "$file" ;;
        esac ;;
esac'
stub gnome-shell 'echo "GNOME Shell 50.1"'
# Installs the zip's version, as gnome-extensions install --force unpacks it
stub gnome-extensions 'dir="$HOME/.local/share/gnome-shell/extensions/vicinae@dagimg-dot"
mkdir -p "$dir"
printf "{\"uuid\": \"vicinae@dagimg-dot\", \"version\": %s}\n" "$(cat "${!#}")" > "$dir/metadata.json"'
# extensions.gnome.org's newest version for GNOME 50
echo 12 > "$STATE/ego-version"
stub curl 'case "$*" in
    *"extension-info/?uuid=vicinae@dagimg-dot&shell_version=50"*) echo "{\"version\": $(cat "$STATE/ego-version")}" ;;
    *) exit 22 ;;
esac'
stub busctl 'case "$*" in
    "--user status org.gnome.Shell") [ -n "${SHELL_STATE:-}" ] ;;
    *GetExtensionInfo*)
        echo "{\"type\":\"a{sv}\",\"data\":[{\"state\":{\"type\":\"d\",\"data\":$SHELL_STATE.0},\"error\":{\"type\":\"s\",\"data\":\"\"}}]}" ;;
esac'
stub systemctl '[ "$1" == --user ] || exit 1
shift
case "$1" in
    show-environment | daemon-reload) ;;
    is-enabled) [ -e "$STATE/${*: -1}.enabled" ] ;;
    is-active)
        case "${*: -1}" in
            graphical-session.target) [ -n "${SESSION:-}" ] ;;
            *) [ -e "$STATE/${*: -1}.active" ] ;;
        esac ;;
    enable) touch "$STATE/${*: -1}.enabled" ;;
    start | restart) touch "$STATE/${*: -1}.active" ;;
    try-restart) ;;
esac'

load_script vicinae/install.sh
as_os ubuntu
bin="$HOME/.local/bin/vicinae"
unit="$HOME/.local/share/systemd/user/vicinae.service"
ext_dir="$HOME/.local/share/gnome-shell/extensions/vicinae@dagimg-dot"
binding=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/dotfiles-vicinae/
gs() { gsettings get "$@"; }
# What the installer writes for --prefix ~/.local, the binary printing $STATE/vicinae-version
replace_fn run_installer 'echo "installer $1 $2 $3 ${*:4} TERM=${TERM:-}" >> "$STUB_LOG"
[ ! -e "$STATE/installer-fails" ] || return 1
mkdir -p "$(dirname "'"$bin"'")" "$(dirname "'"$unit"'")"
printf "#!/bin/sh\ncat \"%s\"\n" "$STATE/vicinae-version" > "'"$bin"'"
chmod +x "'"$bin"'"
echo "ExecStart='"$bin"' server --replace" > "'"$unit"'"'
echo "v0.29.2" > "$STATE/vicinae-version"
replace_fn fetch 'echo "fetch $1" >> "$STUB_LOG"
[ ! -e "$STATE/fetch-fails" ] || return 1
cat "$STATE/ego-version" > "$2"'
# One of yours, on other keys
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
    "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ \
    binding "<Super>Return"
gsettings set org.gnome.shell enabled-extensions "['ubuntu-dock@ubuntu.com']"

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Vicinae ($bin)"
assert_contains "$RUN_OUTPUT" "missing    Vicinae's GNOME extension vicinae@dagimg-dot enabled"
assert_contains "$RUN_OUTPUT" "missing    Super+Space opens Vicinae"
assert_contains "$RUN_OUTPUT" "missing    Super+Space doesn't switch keyboard layouts"

# Over SSH, with no desktop session: it installs everything, and Vicinae starts at the next login
unset TERM
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "installer bash https://vicinae.com/install Vicinae's installer --prefix $HOME/.local TERM=dumb"
assert_contains "$RUN_OUTPUT" "Paste into the active window and snippets stay off, since they need root."
assert_file_contains "$STUB_LOG" "fetch https://extensions.gnome.org/download-extension/vicinae@dagimg-dot.shell-extension.zip?shell_version=50"
assert_contains "$RUN_OUTPUT" "Installed Vicinae's GNOME extension 12. GNOME loads it at your next login."
assert_eq "['ubuntu-dock@ubuntu.com', 'vicinae@dagimg-dot']" "$(gs org.gnome.shell enabled-extensions)" \
    "the enabled extensions, with yours kept"
[ -e "$STATE/vicinae.service.enabled" ] || fail "Vicinae's service wasn't enabled"
assert_contains "$RUN_OUTPUT" "No desktop session, so Vicinae starts at your next login."
assert_contains "$RUN_OUTPUT" "Freed Super+Space from switching keyboard layouts"
assert_eq "['XF86Keyboard']" "$(gs org.gnome.desktop.wm.keybindings switch-input-source)" "the layout switch's keys"
assert_eq "'<Super>space'" "$(gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$binding" binding)" \
    "Vicinae's keys"
assert_eq "\"'$bin' toggle\"" "$(gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$binding" command)" \
    "Vicinae's command"
assert_eq "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/', '$binding']" \
    "$(gs org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" "the shortcut list, with yours kept"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Vicinae ($bin)"
assert_contains "$RUN_OUTPUT" "ok         Vicinae starts at login"
assert_contains "$RUN_OUTPUT" "unverified Vicinae running: no desktop session"
assert_contains "$RUN_OUTPUT" "unverified Vicinae's GNOME extension loaded: GNOME Shell isn't running"
assert_contains "$RUN_OUTPUT" "ok         Super+Space opens Vicinae"
assert_contains "$RUN_OUTPUT" "ok         Super+Space doesn't switch keyboard layouts"

# At the desktop it starts Vicinae; then a re-run changes nothing
export SESSION=1 SHELL_STATE=1
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Started Vicinae."
assert_file_not_contains "$STUB_LOG" "installer"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Vicinae is already running."
assert_file_not_contains "$STUB_LOG" "gsettings set"
assert_file_not_contains "$STUB_LOG" "fetch"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Vicinae running"
assert_contains "$RUN_OUTPUT" "ok         Vicinae's GNOME extension loaded"

# Your own shortcut on Super+Space keeps it, and the step says so
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ \
    binding "<Super>space"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Your shortcut at /org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ has Super+Space, so Vicinae doesn't get it."
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Super+Space for Vicinae: your shortcut at /org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ has it; change one"
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ \
    binding "<Super>Return"

# A layout switch with only Super+Space ends up empty
gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Super>space']"
assert_exit 0 main
assert_eq "@as []" "$(gs org.gnome.desktop.wm.keybindings switch-input-source)" "the layout switch's keys"

# update_vicinae: the installer runs each time, and a new version restarts Vicinae
: > "$STUB_LOG"
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status"
assert_file_contains "$STUB_LOG" "installer bash https://vicinae.com/install"
assert_file_not_contains "$STUB_LOG" "try-restart"
assert_file_not_contains "$STUB_LOG" "fetch"
replace_fn run_installer 'echo "installer $*" >> "$STUB_LOG"; echo v0.30.0 > "$STATE/vicinae-version"'
: > "$STUB_LOG"
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status after a new release"
assert_file_contains "$STUB_LOG" "systemctl --user try-restart vicinae.service"
# A newer extension on extensions.gnome.org is installed
echo 13 > "$STATE/ego-version"
: > "$STUB_LOG"
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status after a new extension"
assert_file_contains "$STUB_LOG" "fetch https://extensions.gnome.org/download-extension/vicinae@dagimg-dot.shell-extension.zip?shell_version=50"
assert_eq 13 "$(jq -r .version "$ext_dir/metadata.json")" "the extension's version after updating"
# extensions.gnome.org unreachable fails the update
stub curl 'exit 7'
run update_vicinae
assert_eq 1 "$RUN_STATUS" "update_vicinae's status without extensions.gnome.org"
assert_contains "$RUN_OUTPUT" "Couldn't check extensions.gnome.org for a newer Vicinae GNOME extension."

# A failed install fails the step but still sets up what it can
rm -rf "$HOME/.local/bin" "$ext_dir"
replace_fn run_installer 'echo "installer $*" >> "$STUB_LOG"; return 1'
: > "$STUB_LOG"
assert_exit 1 main
assert_file_contains "$STUB_LOG" "fetch https://extensions.gnome.org"
[ -f "$ext_dir/metadata.json" ] || fail "the extension wasn't installed after the installer failed"
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status with no Vicinae"

# Ubuntu Server: no GNOME, nothing to do
hide gnome-shell
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "No GNOME desktop, so skipped."
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Vicinae: no GNOME desktop"
assert_file_not_contains "$STUB_LOG" "installer"

as_os macos
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "vicinae: skipped, Ubuntu only" "$RUN_OUTPUT" "the step on macOS"
assert_eq "" "$(cat "$STUB_LOG")" "commands the skipped step ran"

test_done
