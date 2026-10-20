#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# The stream-deck step on Ubuntu: the daemon's files and packages, its user service, the GNOME
# extension, the Gmail app window, Resources, and the root power helper. Stubs stand in for pnpm,
# gsettings, busctl, systemctl, and apt; fake sysfs trees for RAPL and the deck's hidraw node.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"
STATE="$SANDBOX/state"
export SANDBOX STATE
mkdir -p "$STATE"

# Each stub keeps its state in $STATE: SESSION and SHELL_STATE are set per run
stub pnpm 'mkdir -p node_modules'
stub gsettings 'case "$1" in
    get) cat "$STATE/extensions" 2>/dev/null || echo "@as []" ;;
    set) printf "%s\n" "$4" > "$STATE/extensions" ;;
esac'
stub busctl 'case "$*" in
    "--user status org.gnome.Shell") [ -n "${SHELL_STATE:-}" ] ;;
    *GetExtensionInfo*)
        if [ "$SHELL_STATE" == unknown ]; then echo "{\"type\":\"a{sv}\",\"data\":[{}]}"
        else echo "{\"type\":\"a{sv}\",\"data\":[{\"state\":{\"type\":\"d\",\"data\":$SHELL_STATE.0},\"error\":{\"type\":\"s\",\"data\":\"${SHELL_ERROR:-}\"}}]}"; fi ;;
esac'
stub systemctl 'user=""
[ "$1" != --user ] || { user=user-; shift; }
case "$1" in
    show-environment | daemon-reload | try-restart) ;;
    is-enabled) [ -e "$STATE/$user${*: -1}.enabled" ] ;;
    is-active)
        case "${*: -1}" in
            graphical-session.target) [ -n "${SESSION:-}" ] ;;
            *) [ -e "$STATE/$user${*: -1}.active" ] ;;
        esac ;;
    enable) touch "$STATE/$user${*: -1}.enabled"; [ "$2" != --now ] || touch "$STATE/$user${*: -1}.active" ;;
    start | restart) touch "$STATE/$user${*: -1}.active" ;;
esac'
stub dpkg-query '[ "${*: -1}" == resources ] && [ -e "$STATE/resources" ] && printf "install ok installed"'
stub apt-get '[ "${*: -1}" != resources ] || touch "$STATE/resources"'
stub_sudo_exec

# shellcheck disable=SC2034 # the loaded step reads them
the_step() {
    load_script stream-deck/install.sh
    as_os ubuntu
    POWER_SCRIPT="$SANDBOX/libexec/dotfiles-power"
    POWER_UNIT="$SANDBOX/systemd/dotfiles-power.service"
    RAPL_DIR="$SANDBOX/powercap"
    HIDRAW_DIR="$SANDBOX/hidraw"
    DEV_DIR="$SANDBOX/dev"
    APT_UPDATE_RETRY_DELAY=0
}

mkdir -p "$SANDBOX/powercap/intel-rapl:0" "$SANDBOX/dev"
echo 1 > "$SANDBOX/powercap/intel-rapl:0/energy_uj"
node_bin="$HOME/.local/share/mise/installs/node/lts/bin/node"
deck_dir="$HOME/.local/share/dotfiles/stream-deck"
unit="$HOME/.config/systemd/user/dotfiles-stream-deck.service"
echo "@as ['ding@rastersoft.com', 'ubuntu-dock@ubuntu.com']" > "$STATE/extensions"
the_step

# Without Node from mise, it fails before changing anything
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Node LTS isn't at $node_bin. Run bash setup.sh runtimes first."
[ ! -e "$deck_dir" ] || fail "the step changed things without Node"
mkdir -p "$(dirname "$node_bin")"
printf '#!/bin/sh\n' > "$node_bin"
chmod +x "$node_bin"

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    ~/.local/share/dotfiles/stream-deck/daemon.js"
assert_contains "$RUN_OUTPUT" "missing    GNOME extension dotfiles@gpahal.com enabled"
assert_contains "$RUN_OUTPUT" "missing    Power helper ($SANDBOX/libexec/dotfiles-power)"
assert_contains "$RUN_OUTPUT" "info       Stream Deck not attached here"

# Declining sudo still sets up the rest; with no desktop session the daemon waits for login
answer no
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turned on the GNOME extension dotfiles@gpahal.com. It loads at your next login."
assert_contains "$RUN_OUTPUT" "No desktop session, so the daemon starts at your next login."
assert_eq "['ding@rastersoft.com', 'ubuntu-dock@ubuntu.com', 'dotfiles@gpahal.com']" "$(cat "$STATE/extensions")" \
    "the enabled extensions, with yours kept"
for file in daemon.js layout.json package.json pnpm-lock.yaml pnpm-workspace.yaml bin/open-in; do
    cmp -s "$REPO_DIR/stream-deck/linux/$file" "$deck_dir/$file" || fail "$file wasn't copied"
done
[ -x "$deck_dir/bin/open-in" ] || fail "bin/open-in isn't executable"
cmp -s "$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/stats.js" "$deck_dir/stats.js" || fail "stats.js wasn't copied"
[ -f "$deck_dir/images/key-cpu.svg" ] && [ -f "$deck_dir/images/key-editor@2x.png" ] || fail "the images weren't copied"
[ -f "$HOME/.local/share/gnome-shell/extensions/dotfiles@gpahal.com/extension.js" ] || fail "the extension wasn't copied"
assert_file_contains "$STUB_LOG" "pnpm install --frozen-lockfile --prod --config.confirmModulesPurge=false"
assert_file_contains "$unit" "ExecStart=\"$node_bin\" \"$deck_dir/daemon.js\""
assert_file_contains "$HOME/.local/share/applications/dotfiles-gmail.desktop" \
    "StartupWMClass=chrome-mail.google.com__mail_u_0_-Default"
[ -e "$STATE/user-dotfiles-stream-deck.service.enabled" ] || fail "the daemon's service wasn't enabled"
[ ! -e "$SANDBOX/libexec/dotfiles-power" ] || fail "the power helper was installed though sudo was declined"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "unverified GNOME extension loaded: GNOME Shell isn't running"
assert_contains "$RUN_OUTPUT" "unverified Stream Deck daemon running: no desktop session"

# Accepting sudo installs Resources and the power helper, and starts it
answer yes
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install $SANDBOX/libexec/dotfiles-power, which shares the CPU's power for the Power key"
assert_file_contains "$STUB_LOG" "install -y resources"
assert_file_contains "$STUB_LOG" "systemctl enable --now dotfiles-power.service"
assert_file_not_contains "$STUB_LOG" "pnpm"
cmp -s "$REPO_DIR/stream-deck/linux/dotfiles-power" "$SANDBOX/libexec/dotfiles-power" || fail "the power helper wasn't installed"
[ -x "$SANDBOX/libexec/dotfiles-power" ] || fail "the power helper isn't executable"
cmp -s "$REPO_DIR/stream-deck/linux/dotfiles-power.service" "$SANDBOX/systemd/dotfiles-power.service" ||
    fail "the power helper's unit wasn't installed"

# In the desktop session: it starts the daemon, then a second run changes nothing
export SESSION=1 SHELL_STATE=1
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Started the Stream Deck daemon."
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The Stream Deck daemon is already running."
assert_not_contains "$RUN_OUTPUT" "Copied"
assert_not_contains "$RUN_OUTPUT" "Wrote"
assert_eq "" "$(grep -vE '^(gsettings get|busctl --user (status|--json=short call org.gnome.Shell /org/gnome/Shell)|systemctl --user (show-environment|is-)|systemctl is-|dpkg-query)' "$STUB_LOG")" \
    "commands that changed something on a second run"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         GNOME extension loaded"
assert_contains "$RUN_OUTPUT" "ok         Stream Deck daemon running"
assert_contains "$RUN_OUTPUT" "ok         Power helper running"

# A changed daemon file or lockfile restarts the daemon; a changed extension asks for a login
echo "// an edit" >> "$deck_dir/daemon.js"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Restarted the Stream Deck daemon."
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
echo stale > "$deck_dir/node_modules/.dotfiles-lock"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Stream Deck daemon's dependencies"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "pnpm install"
assert_contains "$RUN_OUTPUT" "Restarted the Stream Deck daemon."
echo "// an edit" >> "$HOME/.local/share/gnome-shell/extensions/dotfiles@gpahal.com/extension.js"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The GNOME extension changed; log out and back in to load it."
assert_not_contains "$RUN_OUTPUT" "Restarted"

# The extension's state, as GNOME Shell reports it
SHELL_STATE=unknown assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    GNOME extension loaded: log out and back in, since GNOME loads a new extension at login"
SHELL_STATE=4 assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "it doesn't list this GNOME version in metadata.json"
SHELL_STATE=3 SHELL_ERROR="TypeError: x is undefined" assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    GNOME extension loaded: it failed: TypeError: x is undefined"
rm "$STATE/user-dotfiles-stream-deck.service.active"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Stream Deck daemon running: journalctl --user -u dotfiles-stream-deck.service says why it stopped"
touch "$STATE/user-dotfiles-stream-deck.service.active"

# The deck attached: its hidraw node must be readable and writable
mkdir -p "$SANDBOX/hidraw/hidraw3/device" "$SANDBOX/hidraw/hidraw1/device"
echo "HID_ID=0003:00000FD9:00000080" > "$SANDBOX/hidraw/hidraw3/device/uevent"
echo "HID_ID=0003:0000046D:0000C52B" > "$SANDBOX/hidraw/hidraw1/device/uevent"
touch "$SANDBOX/dev/hidraw3"
chmod 000 "$SANDBOX/dev/hidraw3"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Stream Deck readable at $SANDBOX/dev/hidraw3: no access"
assert_not_contains "$RUN_OUTPUT" "hidraw1"
chmod 600 "$SANDBOX/dev/hidraw3"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Stream Deck readable at $SANDBOX/dev/hidraw3"

# A CPU without RAPL has no power helper to install
rm -r "$SANDBOX/powercap"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Power key: this CPU has no RAPL power counter"
assert_not_contains "$RUN_OUTPUT" "Power helper"

# The power helper: watts from two readings, across the counter wrapping
rapl="$SANDBOX/rapl"
mkdir -p "$rapl/intel-rapl:0" "$rapl/intel-rapl:0:0"
echo 100000000 > "$rapl/intel-rapl:0/max_energy_range_uj"
echo 99000000 > "$rapl/intel-rapl:0/energy_uj"
echo 5000000 > "$rapl/intel-rapl:0:0/energy_uj"
stub date 'n=$(($(cat "$SANDBOX/date-n" 2>/dev/null || echo 0) + 1)); echo "$n" > "$SANDBOX/date-n"; echo "$((n * 2000000000))"'
# The second sleep fails, which ends the helper's loop
stub sleep '[ -e "$SANDBOX/slept" ] && exit 1
touch "$SANDBOX/slept"
echo 19000000 > "$SANDBOX/rapl/intel-rapl:0/energy_uj"
echo 35000000 > "$SANDBOX/rapl/intel-rapl:0:0/energy_uj"'
DOTFILES_RAPL_DIR="$rapl" DOTFILES_POWER_FILE="$SANDBOX/power" assert_exit 0 bash "$REPO_DIR/stream-deck/linux/dotfiles-power"
assert_eq "10.00 15.00" "$(cat "$SANDBOX/power")" "the package's and cores' watts over 2 s"
[ -n "$(find "$SANDBOX/power" -perm 644)" ] || fail "the power file isn't world-readable"

test_done
