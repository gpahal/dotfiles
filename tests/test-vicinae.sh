#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# The vicinae step. On Ubuntu: Vicinae from its installer into ~/.local, its GNOME extension from
# extensions.gnome.org, its user service, and Super+Space; and update_vicinae, which upgrade runs.
# On both OSes: the shared settings file, settings.json's import and per-OS keys, and the keys it
# overrides. A fake installer writes what the real one does for a prefix under HOME.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"
STATE="$SANDBOX/state"
export STATE
mkdir -p "$STATE"
stub_gsettings
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
# daemon-reload loads the unit
stub systemctl '[ "$1" == --user ] || exit 1
shift
case "$1" in
    show-environment) ;;
    daemon-reload) touch "$STATE/loaded" ;;
    show) if [ -e "$STATE/loaded" ]; then echo loaded; else echo not-found; fi ;;
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
settings="$HOME/.config/vicinae/settings.json"
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
assert_contains "$RUN_OUTPUT" "missing    ~/.config/vicinae/dotfiles.json"
assert_contains "$RUN_OUTPUT" "missing    $settings imports dotfiles.json"
assert_contains "$RUN_OUTPUT" "missing    Paste into the active window and snippets off (input_server.enabled): not set"

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
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
assert_contains "$RUN_OUTPUT" "No desktop session, so Vicinae starts at your next login."
assert_contains "$RUN_OUTPUT" "Freed Super+Space from switching keyboard layouts"
assert_eq "['XF86Keyboard']" "$(gs org.gnome.desktop.wm.keybindings switch-input-source)" "the layout switch's keys"
assert_eq "'<Super>space'" "$(gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$binding" binding)" \
    "Vicinae's keys"
assert_eq "\"'$bin' toggle\"" "$(gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$binding" command)" \
    "Vicinae's command"
assert_eq "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/', '$binding']" \
    "$(gs org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" "the shortcut list, with yours kept"
cmp -s "$REPO_DIR/vicinae/dotfiles.json" "$HOME/.config/vicinae/dotfiles.json" || fail "the shared settings weren't copied"
assert_eq '{"imports":["dotfiles.json"],"input_server":{"enabled":false}}' "$(jq -c . "$settings")" "settings.json"
assert_contains "$RUN_OUTPUT" "$settings imports dotfiles.json"
assert_contains "$RUN_OUTPUT" "Paste into the active window and snippets off (input_server.enabled = false)"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Vicinae ($bin)"
assert_contains "$RUN_OUTPUT" "ok         Vicinae starts at login"
assert_contains "$RUN_OUTPUT" "unverified Vicinae running: no desktop session"
assert_contains "$RUN_OUTPUT" "unverified Vicinae's GNOME extension loaded: GNOME Shell isn't running"
assert_contains "$RUN_OUTPUT" "ok         Super+Space opens Vicinae"
assert_contains "$RUN_OUTPUT" "ok         Super+Space doesn't switch keyboard layouts"
assert_contains "$RUN_OUTPUT" "ok         ~/.config/vicinae/dotfiles.json"
assert_contains "$RUN_OUTPUT" "ok         $settings imports dotfiles.json"
assert_contains "$RUN_OUTPUT" "ok         Paste into the active window and snippets off (input_server.enabled): false"
assert_not_contains "$RUN_OUTPUT" "overrides"

# At the desktop it starts Vicinae; then a re-run changes nothing
export SESSION=1 SHELL_STATE=1
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Started Vicinae."
assert_file_not_contains "$STUB_LOG" "installer"
: > "$STUB_LOG"
cp "$settings" "$SANDBOX/settings-before"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Vicinae is already running."
assert_contains "$RUN_OUTPUT" "$settings already imports dotfiles.json and has this OS's settings"
assert_file_not_contains "$STUB_LOG" "gsettings set"
assert_file_not_contains "$STUB_LOG" "fetch"
assert_file_not_contains "$STUB_LOG" "daemon-reload"
cmp -s "$settings" "$SANDBOX/settings-before" || fail "a re-run changed settings.json"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Vicinae running"
assert_contains "$RUN_OUTPUT" "ok         Vicinae's GNOME extension loaded"

# Vicinae's own settings.json: a comment header, and its settings window's changes, which win.
# Status names the repo's keys it overrides; with the import there, the step leaves it as it is.
cat > "$settings" << 'EOF'
// This configuration is merged with the default vicinae configuration file.
// Learn more about configuration at https://docs.vicinae.com/config

{
  "favorites": ["clipboard:history", "applications:org.gnome.Nautilus"],
  "imports": ["dotfiles.json"],
  "input_server": { "enabled": false }, /* yours */
  "theme": { "dark": { "name": "my // theme" } },
  "providers": { "clipboard": { "preferences": {} } }
}
EOF
cp "$settings" "$SANDBOX/settings-before"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "info       $settings overrides the repo's dotfiles.json for: favorites, theme.dark.name"
assert_exit 0 main
cmp -s "$settings" "$SANDBOX/settings-before" || fail "the step rewrote settings.json, which already had the import"
# Without the import, it's added, and your keys stay
grep -v '"imports"' "$settings" > "$SANDBOX/settings" && mv "$SANDBOX/settings" "$settings"
assert_exit 0 main
assert_eq '["dotfiles.json"]' "$(jq -c .imports "$settings")" "settings.json's imports"
assert_eq '["clipboard:history","applications:org.gnome.Nautilus"]' "$(jq -c .favorites "$settings")" "your favorites"
assert_eq '"my // theme"' "$(jq -c .theme.dark.name "$settings")" "your theme"
# Your value for an OS key stays
jq '.input_server.enabled = true' "$settings" > "$SANDBOX/settings" && mv "$SANDBOX/settings" "$settings"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Kept your input_server.enabled in $settings, true. The repo's is false."
assert_eq true "$(jq -c .input_server.enabled "$settings")" "your input_server.enabled"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Paste into the active window and snippets off (input_server.enabled): yours, true (the repo's is false)"
# Invalid JSON fails the step and stays as it is
printf '{ "favorites": [\n' > "$settings"
cp "$settings" "$SANDBOX/settings-before"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$settings isn't a JSON object, even without its comments, so it was left as it is."
cmp -s "$settings" "$SANDBOX/settings-before" || fail "the step changed an invalid settings.json"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $settings isn't a JSON object, even without its comments"
rm "$settings"

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

# macOS: the homebrew step's app, and settings.json with Cmd+Space and paste on
as_os macos
rm -rf "$HOME/.config/vicinae"
VICINAE_APP="$SANDBOX/Vicinae.app"
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Vicinae isn't installed. Run bash setup.sh homebrew first."
[ ! -e "$HOME/.config/vicinae" ] || fail "the step wrote settings without Vicinae"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Vicinae ($VICINAE_APP): bash setup.sh homebrew installs it"
mkdir -p "$VICINAE_APP"
assert_exit 0 main
assert_eq '{"imports":["dotfiles.json"],"global_shortcuts":{"toggle":"control+SPACE"},"input_server":{"enabled":true}}' \
    "$(jq -c . "$settings")" "settings.json on macOS"
assert_contains "$RUN_OUTPUT" 'Cmd+Space opens Vicinae (global_shortcuts.toggle = "control+SPACE")'
assert_contains "$RUN_OUTPUT" "Paste into the active window and snippets on (input_server.enabled = true)"
cmp -s "$REPO_DIR/vicinae/dotfiles.json" "$HOME/.config/vicinae/dotfiles.json" || fail "the shared settings weren't copied on macOS"
assert_eq "" "$(cat "$STUB_LOG")" "commands the step ran on macOS"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Vicinae ($VICINAE_APP)"
assert_contains "$RUN_OUTPUT" "ok         $settings imports dotfiles.json"
assert_contains "$RUN_OUTPUT" 'ok         Cmd+Space opens Vicinae (global_shortcuts.toggle): "control+SPACE"'
jq '.global_shortcuts.toggle = "alt+SPACE"' "$settings" > "$SANDBOX/settings" && mv "$SANDBOX/settings" "$settings"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Kept your global_shortcuts.toggle in $settings, \"alt+SPACE\". The repo's is \"control+SPACE\"."
assert_eq '"alt+SPACE"' "$(jq -c .global_shortcuts.toggle "$settings")" "your shortcut"
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status on macOS"
assert_eq "" "$(cat "$STUB_LOG")" "commands update_vicinae ran on macOS"

test_done
