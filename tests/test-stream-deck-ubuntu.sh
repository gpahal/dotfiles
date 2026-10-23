#!/bin/bash
# shellcheck disable=SC2329

# The stream-deck step on Ubuntu: the daemon's files and packages, its user service, the GNOME
# extension, the Gmail app window, Resources, and the root power helper. Stubs stand in for pnpm,
# gsettings, busctl, systemctl, and apt; fake sysfs trees for RAPL and the deck's hidraw node.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &> /dev/null || skip "jq isn't installed"
STATE="$SANDBOX/state"

# SESSION and SHELL_STATE are set per run
stub_gnome_session "$STATE"
stub pnpm 'mkdir -p node_modules'
stub_apt_packages
stub_sudo_exec

# shellcheck disable=SC2034 # the loaded step reads it
the_step() {
    load_script stream-deck/install.sh
    sandbox_paths RAPL_DIR="$SANDBOX/powercap" HIDRAW_DIR="$SANDBOX/hidraw" stream-deck/install.sh 'stream-deck/lib/*.sh'
    as_os ubuntu
    APT_UPDATE_RETRY_DELAY=0
}

mkdir -p "$SANDBOX/powercap/intel-rapl:0" "$SANDBOX/dev"
echo 1 > "$SANDBOX/powercap/intel-rapl:0/energy_uj"
node_bin="$HOME/.local/share/mise/installs/node/lts/bin/node"
deck_dir="$HOME/.local/share/dotfiles/stream-deck"
echo "@as ['ding@rastersoft.com', 'ubuntu-dock@ubuntu.com']" > "$SANDBOX/gsettings/org.gnome.shell.enabled-extensions"
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
assert_contains "$RUN_OUTPUT" "missing    Power helper ($SANDBOX/usr/local/libexec/dotfiles-power)"
assert_contains "$RUN_OUTPUT" "info       Stream Deck not attached here"

# Declining sudo still sets up the rest; with no desktop session the daemon waits for login
answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turned on the GNOME extension dotfiles@gpahal.com. It loads at your next login."
assert_contains "$RUN_OUTPUT" "No desktop session, so the Stream Deck daemon starts at your next login."
[ -e "$STATE/user-dotfiles-stream-deck.service.enabled" ] || fail "the daemon's service wasn't enabled"
[ ! -e "$SANDBOX/usr/local/libexec/dotfiles-power" ] || fail "the power helper was installed though sudo was declined"
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "unverified GNOME extension loaded: GNOME Shell isn't running"
assert_contains "$RUN_OUTPUT" "unverified Stream Deck daemon running: no desktop session"

# Accepting sudo installs Resources and the power helper, and starts it
answer yes
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install $SANDBOX/usr/local/libexec/dotfiles-power, which shares the CPU's power for the Power key"
assert_file_contains "$STUB_LOG" "install -y resources"
assert_file_contains "$STUB_LOG" "systemctl enable --now dotfiles-power.service"
assert_file_not_contains "$STUB_LOG" "pnpm"

# In the desktop session: it starts the daemon, then a second run changes nothing
export SESSION=1 SHELL_STATE=1
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Started the Stream Deck daemon."
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The Stream Deck daemon is already running."
assert_not_contains "$RUN_OUTPUT" "Copied"
assert_not_contains "$RUN_OUTPUT" "Wrote"
assert_eq "" "$(grep -vE '^(gsettings get|busctl --user (status|--json=short call org.gnome.Shell /org/gnome/Shell)|systemctl --user (show-environment|show -p|is-)|systemctl is-|dpkg-query)' "$STUB_LOG")" \
    "commands that changed something on a second run"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         GNOME extension loaded"
assert_contains "$RUN_OUTPUT" "ok         Stream Deck daemon running"
assert_contains "$RUN_OUTPUT" "ok         Power helper running"

# A changed daemon file or lockfile restarts the daemon; a changed extension asks for a login
echo "// an edit" >> "$deck_dir/daemon.js"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Restarted the Stream Deck daemon."
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
echo stale > "$deck_dir/node_modules/.dotfiles-lock"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Stream Deck daemon's dependencies"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "pnpm install"
assert_contains "$RUN_OUTPUT" "Restarted the Stream Deck daemon."
echo "// an edit" >> "$HOME/.local/share/gnome-shell/extensions/dotfiles@gpahal.com/extension.js"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The GNOME extension changed; log out and back in to load it."
assert_not_contains "$RUN_OUTPUT" "Restarted"

# A failed reload leaves the restart pending, and the next run does it
echo "// an edit" >> "$deck_dir/daemon.js"
touch "$STATE/reload-fails"
assert_exit 1 main
assert_not_contains "$RUN_OUTPUT" "Restarted"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Stream Deck daemon restarted on its new files: re-run the stream-deck step"
rm "$STATE/reload-fails"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Restarted the Stream Deck daemon."
assert_file_contains "$STUB_LOG" "systemctl --user restart dotfiles-stream-deck.service"
assert_exit 0 main --status
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The Stream Deck daemon is already running."

# Files the repo no longer has go, as does a folder they leave empty, but not the packages
mkdir -p "$deck_dir/old" "$deck_dir/node_modules/pkg/empty"
touch "$deck_dir/images/key-old.svg" "$deck_dir/old/x.js" "$deck_dir/node_modules/pkg/index.js"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    ~/.local/share/dotfiles/stream-deck/images/key-old.svg: the repo no longer has it"
assert_contains "$RUN_OUTPUT" "missing    ~/.local/share/dotfiles/stream-deck/old/x.js"
assert_not_contains "$RUN_OUTPUT" "node_modules"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Removed images/key-old.svg, which the repo no longer has"
assert_contains "$RUN_OUTPUT" "Restarted the Stream Deck daemon."
[ ! -e "$deck_dir/images/key-old.svg" ] && [ ! -e "$deck_dir/old" ] || fail "the stale files weren't removed"
[ -f "$deck_dir/node_modules/pkg/index.js" ] && [ -d "$deck_dir/node_modules/pkg/empty" ] ||
    fail "the daemon's packages were changed"
[ -f "$deck_dir/images/key-cpu.svg" ] || fail "a current image was removed"
assert_exit 0 main --status

# A stopped daemon
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

# The power helper: watts from two readings, across each counter wrapping at its own range. The
# cores are the zone named core, not the first child zone.
rapl="$SANDBOX/rapl/intel-rapl:0"
mkdir -p "$rapl" "$rapl:0" "$rapl:1"
echo package-0 > "$rapl/name"
echo 100000000 > "$rapl/max_energy_range_uj"
echo 99000000 > "$rapl/energy_uj"
echo dram > "$rapl:0/name"
echo 1 > "$rapl:0/energy_uj"
echo core > "$rapl:1/name"
echo 50000000 > "$rapl:1/max_energy_range_uj"
echo 45000000 > "$rapl:1/energy_uj"
echo "100.00 1.00" > "$SANDBOX/uptime"
# Each sleep logs the last line and sets the next readings, 2 s on. The cores' counter can't be
# read in the second round, so the third spans 4 s for them. The fourth sleep ends the loop.
stub sleep 'n=$(($(cat "$SANDBOX/sleeps" 2>/dev/null || echo 0) + 1))
echo "$n" > "$SANDBOX/sleeps"
r="$SANDBOX/rapl/intel-rapl:0"
[ "$n" -eq 1 ] || cat "$SANDBOX/power" >> "$SANDBOX/power.log"
case "$n" in
    1) echo 19000000 > "$r/energy_uj"; echo 5000000 > "$r:1/energy_uj"; echo "102.00 1.00" > "$SANDBOX/uptime" ;;
    2) echo 39000000 > "$r/energy_uj"; rm "$r:1/energy_uj"; echo "104.00 1.00" > "$SANDBOX/uptime" ;;
    3) echo 59000000 > "$r/energy_uj"; echo 25000000 > "$r:1/energy_uj"; echo "106.00 1.00" > "$SANDBOX/uptime" ;;
    *) exit 1 ;;
esac'
DOTFILES_RAPL_DIR="$SANDBOX/rapl" DOTFILES_POWER_FILE="$SANDBOX/power" DOTFILES_UPTIME_FILE="$SANDBOX/uptime" \
    assert_exit 0 bash "$REPO_DIR/stream-deck/linux/dotfiles-power"
assert_eq "10.00 5.00
10.00
10.00 5.00" "$(cat "$SANDBOX/power.log")" "the package's and cores' watts each round"
[ -n "$(find "$SANDBOX/power" -perm 644)" ] || fail "the power file isn't world-readable"
# A cores' counter unreadable at startup is read again each round; its figure starts a round later
rm "$SANDBOX/sleeps" "$SANDBOX/power.log" "$rapl:1/energy_uj"
echo 99000000 > "$rapl/energy_uj"
echo "100.00 1.00" > "$SANDBOX/uptime"
DOTFILES_RAPL_DIR="$SANDBOX/rapl" DOTFILES_POWER_FILE="$SANDBOX/power" DOTFILES_UPTIME_FILE="$SANDBOX/uptime" \
    assert_exit 0 bash "$REPO_DIR/stream-deck/linux/dotfiles-power"
assert_eq "10.00
10.00
10.00 5.00" "$(cat "$SANDBOX/power.log")" "the watts with the cores' counter unreadable at startup"

test_done
