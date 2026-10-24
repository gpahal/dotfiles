#!/bin/bash
# shellcheck disable=SC2329

# The vicinae step. On Ubuntu: libopengl0 from apt, Vicinae from its installer into ~/.local, its GNOME extension from
# extensions.gnome.org, its user service, and Super+Space; and update_vicinae, which upgrade runs.
# On both OSes: the shared settings file, settings.json's import and per-OS keys, and the keys it
# overrides. A fake installer writes what the real one does for a prefix under HOME.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &> /dev/null || skip "jq isn't installed"
STATE="$SANDBOX/state"
export STATE
stub_gnome_session "$STATE"
# Installs the zip's version, as gnome-extensions install --force unpacks it
stub gnome-extensions 'dir="$HOME/.local/share/gnome-shell/extensions/vicinae@dagimg-dot"
mkdir -p "$dir"
printf "{\"uuid\": \"vicinae@dagimg-dot\", \"version\": %s}\n" "$(cat "${!#}")" > "$dir/metadata.json"'
# extensions.gnome.org's newest version for GNOME 50, and its zip, which holds the version
ego_version() {
    echo "{\"version\": $1}" > "$STATE/ego-info.json"
    echo "$1" > "$STATE/ego.zip"
}
ego_version 12
stub_fetch "https://extensions.gnome.org/extension-info/?uuid=vicinae@dagimg-dot&shell_version=50=$STATE/ego-info.json" \
    "https://extensions.gnome.org/download-extension/vicinae@dagimg-dot.shell-extension.zip?shell_version=50=$STATE/ego.zip"
stub_sudo_exec
stub_apt_packages

load_script vicinae/install.sh
as_os ubuntu
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0
bin="$HOME/.local/bin/vicinae"
unit="$HOME/.local/share/systemd/user/vicinae.service"
ext_dir="$HOME/.local/share/gnome-shell/extensions/vicinae@dagimg-dot"
settings="$HOME/.config/vicinae/settings.json"
binding=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/dotfiles-vicinae/
gs() { gsettings get "$@"; }
# What the installer writes for --prefix ~/.local, the binary printing $STATE/vicinae-version
replace_fn run_installer 'echo "installer $1 $2 $3 ${*:4} TERM=${TERM:-}" >> "$STUB_LOG"
[ ! -e "$STATE/installer-fails" ] || return 1
mkdir -p "$(dirname "'"$unit"'")"
stub_at "'"$bin"'" "cat \"$STATE/vicinae-version\""
echo "ExecStart='"$bin"' server --replace" > "'"$unit"'"'
echo "v0.29.2" > "$STATE/vicinae-version"
user_shortcut
gsettings set org.gnome.shell enabled-extensions "['ubuntu-dock@ubuntu.com']"
# GNOME's default
gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Super>space', 'XF86Keyboard']"

assert_exit 3 main --status

# Over SSH, with no desktop session: it installs everything, and Vicinae starts at the next login
unset TERM
: > "$STUB_LOG"
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "install -y libopengl0"
assert_file_contains "$STUB_LOG" "installer bash https://vicinae.com/install Vicinae's installer --prefix $HOME/.local TERM=dumb"
assert_file_contains "$STUB_LOG" "https://extensions.gnome.org/download-extension/vicinae@dagimg-dot.shell-extension.zip?shell_version=50"
[ -e "$STATE/user-vicinae.service.enabled" ] || fail "Vicinae's service wasn't enabled"
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
assert_eq "['XF86Keyboard']" "$(gs org.gnome.desktop.wm.keybindings switch-input-source)" "the layout switch's keys"
assert_eq "'<Super>space'" "$(gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$binding" binding)" \
    "Vicinae's keys"
assert_eq "\"'$bin' toggle\"" "$(gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$binding" command)" \
    "Vicinae's command"
assert_eq '{"imports":["dotfiles.json"],"input_server":{"enabled":false}}' "$(jq -c . "$settings")" "settings.json"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified Vicinae running: no desktop session"
assert_not_contains "$RUN_OUTPUT" "overrides"

# At the desktop it starts Vicinae; then a re-run changes nothing
export SESSION=1 SHELL_STATE=1
assert_idempotent main
assert_contains "$FIRST_OUTPUT" "Started Vicinae."
assert_not_contains "$FIRST_LOG" "installer" "the first run's commands"
assert_file_not_contains "$STUB_LOG" "download-extension"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Vicinae running"
assert_contains "$RUN_OUTPUT" "ok         Vicinae's GNOME extension loaded"

# Declining sudo leaves libopengl0 out without failing the step, and status still names it
stub_apt_packages
answer no
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    libopengl0, which Vicinae needs to start"
assert_sudo_noninteractive
stub_apt_packages libopengl0

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
snapshot "$settings"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "info       $settings overrides the repo's dotfiles.json for: favorites, theme.dark.name"
assert_exit 0 main
assert_unchanged "$settings" "though it already had the import"
# Without the import, it's added, and your keys stay
grep -v '"imports"' "$settings" > "$SANDBOX/settings" && mv "$SANDBOX/settings" "$settings"
assert_exit 0 main
assert_eq '["dotfiles.json"]' "$(jq -c .imports "$settings")" "settings.json's imports"
assert_eq '["clipboard:history","applications:org.gnome.Nautilus"]' "$(jq -c .favorites "$settings")" "your favorites"
assert_eq '"my // theme"' "$(jq -c .theme.dark.name "$settings")" "your theme"
# Your value for an OS key stays
jq_edit "$settings" '.input_server.enabled = true'
assert_exit 0 main
assert_eq true "$(jq -c .input_server.enabled "$settings")" "your input_server.enabled"
assert_exit 0 main --status
# Invalid JSON fails the step and stays as it is
printf '{ "favorites": [\n' > "$settings"
snapshot "$settings"
assert_exit 1 main
assert_unchanged "$settings" "though it was invalid"
assert_exit 3 main --status
rm "$settings"

# A layout switch with only Super+Space ends up empty
gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Super>space']"
assert_exit 0 main
assert_eq "@as []" "$(gs org.gnome.desktop.wm.keybindings switch-input-source)" "the layout switch's keys"

# update_vicinae: the installer runs each time, and a new version restarts Vicinae
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status"
assert_file_contains "$STUB_LOG" "installer bash https://vicinae.com/install"
assert_file_not_contains "$STUB_LOG" "try-restart"
assert_file_not_contains "$STUB_LOG" "download-extension"
replace_fn run_installer 'echo "installer $*" >> "$STUB_LOG"; echo v0.30.0 > "$STATE/vicinae-version"'
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status after a new release"
assert_file_contains "$STUB_LOG" "systemctl --user try-restart vicinae.service"
# A newer extension on extensions.gnome.org is installed
ego_version 13
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status after a new extension"
assert_file_contains "$STUB_LOG" "https://extensions.gnome.org/download-extension/vicinae@dagimg-dot.shell-extension.zip?shell_version=50"
assert_eq 13 "$(jq -r .version "$ext_dir/metadata.json")" "the extension's version after updating"
# extensions.gnome.org unreachable fails the update
touch "$SANDBOX/fetch-fails"
run update_vicinae
assert_eq 1 "$RUN_STATUS" "update_vicinae's status without extensions.gnome.org"
rm "$SANDBOX/fetch-fails"

# A failed install fails the step but still sets up what it can
rm -rf "$HOME/.local/bin" "$ext_dir"
replace_fn run_installer 'echo "installer $*" >> "$STUB_LOG"; return 1'
assert_exit 1 main
assert_file_contains "$STUB_LOG" "https://extensions.gnome.org/download-extension/"
[ -f "$ext_dir/metadata.json" ] || fail "the extension wasn't installed after the installer failed"
run update_vicinae
assert_eq 0 "$RUN_STATUS" "update_vicinae's status with no Vicinae"

# Ubuntu Server: no GNOME, nothing to do
hide gnome-shell
assert_exit 0 main
cp "$STUB_LOG" "$SANDBOX/both.log"
assert_exit 0 main --status
cat "$STUB_LOG" >> "$SANDBOX/both.log"
assert_file_not_contains "$SANDBOX/both.log" "installer"

# macOS: the homebrew step's app, and settings.json with Cmd+Space and paste on
as_os macos
rm -rf "$HOME/.config/vicinae"
VICINAE_APP="$SANDBOX/Vicinae.app"
assert_exit 1 main
cp "$STUB_LOG" "$SANDBOX/all.log"
assert_contains "$RUN_OUTPUT" "Vicinae isn't installed"
[ ! -e "$HOME/.config/vicinae" ] || fail "the step wrote settings without Vicinae"
assert_exit 3 main --status
cat "$STUB_LOG" >> "$SANDBOX/all.log"
mkdir -p "$VICINAE_APP"
assert_exit 0 main
cat "$STUB_LOG" >> "$SANDBOX/all.log"
assert_eq '{"imports":["dotfiles.json"],"global_shortcuts":{"toggle":"control+SPACE"},"input_server":{"enabled":true}}' \
    "$(jq -c . "$settings")" "settings.json on macOS"
assert_eq "" "$(cat "$SANDBOX/all.log")" "commands the step ran on macOS"
assert_exit 0 main --status
cp "$STUB_LOG" "$SANDBOX/both.log"
run update_vicinae
cat "$STUB_LOG" >> "$SANDBOX/both.log"
assert_eq 0 "$RUN_STATUS" "update_vicinae's status on macOS"
assert_eq "" "$(cat "$SANDBOX/both.log")" "commands update_vicinae ran on macOS"

test_done
