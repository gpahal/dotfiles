#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The ubuntu step's UPS part (ubuntu/lib/ups.sh): no UPS on USB, which installs nothing, a UPS
# plugged in on a later run, which installs NUT and sets it up, an unchanged second run, a stale
# notifier or RTC wake hook, NUT's files unreadable without sudo, a stopped service or driver, a
# changed UPS, NUT removed, no upower hwdb, and a VM. And upsmon's notifier (ubuntu/ups-notify.sh), which pushes each event to ntfy.
# /etc/nut, the notifier's and RTC wake hook's install paths, and upower's hwdb point into the
# sandbox, and every command they'd run is a stub.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ubuntu/install.sh
is_ubuntu() { true; }

NUT_DIR="$SANDBOX/nut"
UPS_NOTIFY="$SANDBOX/libexec/dotfiles-ups-notify"
NTFY_LIB="$SANDBOX/lib-dotfiles/ntfy.sh"
UPS_RTC_HOOK="$SANDBOX/system-shutdown/dotfiles-rtc-wake"
UPOWER_HWDB="$SANDBOX/95-upower-hid.hwdb"
mkdir -p "$NUT_DIR" "$SANDBOX/udev"
touch "$UPOWER_HWDB"

# udevadm info --export-db prints a block per device in $SANDBOX/udev, each followed by a blank
# line, and fails while $SANDBOX/udev-fails exists. trigger only logs.
stub udevadm '[ "$1 $2" == "info --export-db" ] || exit 0
[ ! -e "'"$SANDBOX"'/udev-fails" ] || exit 1
for f in "'"$SANDBOX"'"/udev/*; do [ ! -e "$f" ] || { cat "$f"; echo; }; done'
# A USB device in udev's database, with its IDs, as udev's usb_id and hwdb builtins tag it. upower's
# hwdb tags a UPS with UPOWER_BATTERY_TYPE=ups, which its rules copy to the hiddev device under it,
# without the IDs.
usb_device() {
    {
        echo "P: /devices/pci0000:00/0000:00:14.0/usb1/$1"
        echo "E: DEVPATH=/devices/pci0000:00/0000:00:14.0/usb1/$1"
        echo "E: SUBSYSTEM=usb"
        echo "E: DEVTYPE=usb_device"
        echo "E: ID_VENDOR_ID=$2"
        echo "E: ID_MODEL_ID=$3"
        [ "${4:-}" != ups ] || printf '%s\n' "E: UPOWER_BATTERY_TYPE=ups" "E: UPOWER_VENDOR=Cyber Power Systems"
    } > "$SANDBOX/udev/$1"
    [ "${4:-}" == ups ] || return 0
    printf '%s\n' "P: /devices/pci0000:00/0000:00:14.0/usb1/$1/$1:1.0/usbmisc/hiddev0" \
        "E: SUBSYSTEM=usbmisc" "E: UPOWER_BATTERY_TYPE=ups" "E: ID_VENDOR=CPS" > "$SANDBOX/udev/$1-hiddev"
}
unplug() { rm -f "$SANDBOX/udev/$1" "$SANDBOX/udev/$1-hiddev"; }
# A root hub and a keyboard, neither a UPS
usb_device usb1 1d6b 0002
usb_device 1-2 046d c52b

# sudo runs the command, refuses a path under /etc, /usr, or /run, and skips chgrp, since the test
# runs as you, without a nut group. sudo -n fails while $SANDBOX/no-sudo exists, as it does
# without cached credentials.
stub sudo 'if [ "$1" == -n ]; then
    [ ! -e "'"$SANDBOX"'/no-sudo" ] || exit 1
    shift
fi
for a in "$@"; do case "$a" in /etc/* | /usr/* | /run/*) echo "refused: $a" >&2; exit 1 ;; esac; done
[ "$1" != chgrp ] || exit 0
exec env "$@"'
# nut-scanner prints $SANDBOX/scan, as nut-scanner -U -q prints what it finds
stub nut-scanner 'cat "'"$SANDBOX"'/scan" 2> /dev/null || true'
# NUT 2.8.2 and later name, after the driver, others that could serve the UPS
scan() {
    printf '%s\n' "[nutdev-usb1]" "	driver = \"$1\"	# alternately: apc_modbus" '	port = "auto"' "	vendorid = \"$2\"" \
        "	productid = \"$3\"" '	product = "CP1500PFCLCD"' '	serial = "CXXNV2000123"' '	vendor = "CPS"' \
        '	# bus = "001"' '	# device = "004"' '	# busport = "002"' > "$SANDBOX/scan"
}
# The NUT packages are installed once $SANDBOX/nut-installed exists, which apt-get install makes
stub dpkg-query 'case "${!#}" in
    nut-client | nut-server) [ -e "'"$SANDBOX"'/nut-installed" ] && echo "install ok installed" ;;
    *) echo "install ok installed" ;;
esac'
stub apt-get '[[ " $* " != *" install "* ]] || touch "'"$SANDBOX"'/nut-installed"'
# upsc answers from $SANDBOX/upsc, one "<var>: <value>" line each, and fails without it, as when
# upsd or the driver isn't running
stub upsc '[ -e "'"$SANDBOX"'/upsc" ] || { echo "Error: Driver not connected" >&2; exit 1; }
sed -n "s/^$2: //p" "'"$SANDBOX"'/upsc"'
upsc_answers() {
    printf '%s\n' "ups.status: $1" "battery.charge: 100" "ups.vendorid: $2" "ups.productid: $3" > "$SANDBOX/upsc"
}
# A unit is active once systemctl restart or start ran it, until $SANDBOX/active-<unit> is
# removed. is-active succeeds when any unit given is active, as systemctl's does.
stub systemctl 'cmd="$1"
shift
case "$cmd" in
    is-active)
        [ "$1" != -q ] || shift
        for unit in "$@"; do [ ! -e "'"$SANDBOX"'/active-$unit" ] || exit 0; done
        exit 3 ;;
    restart | start) for unit in "$@"; do touch "'"$SANDBOX"'/active-$unit"; done ;;
esac'
stub systemd-detect-virt 'exit 1'

# --- no UPS on USB ---
# Nothing to do, nothing asked, and nothing installed: a later run looks again. Status skips it, so
# a machine without a UPS doesn't need attention every day.
assert_eq "" "$(ups_todo)" "what the UPS part needs with no UPS on USB"
assert_exit 0 status_ups
assert_contains "$RUN_OUTPUT" "skipped    UPS monitored by NUT: no UPS on USB; plug in the UPS's USB cable and re-run the ubuntu step"
run warn_no_ups
assert_contains "$RUN_OUTPUT" "No UPS on USB, so NUT isn't set up"
[ ! -e "$SANDBOX/nut-installed" ] || fail "NUT was installed without a UPS"

# --- a UPS plugged in on a later run ---
# NUT isn't installed yet: the step installs it, has udev apply its rules to the UPS, and finds the
# UPS with nut-scanner. One nut-scanner can't find yet writes nothing.
usb_device 1-3 0764 0501 ups
assert_contains "$(ups_todo)" "UPS: install nut-client and nut-server, and set up NUT for the UPS on USB (0764:0501)"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS on USB (0764:0501) monitored by NUT: nut-client and nut-server aren't installed (re-run the ubuntu step)"
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y nut-client nut-server"
assert_file_contains "$STUB_LOG" "sudo udevadm trigger --settle --subsystem-match=usb --action=change"
assert_file_contains "$STUB_LOG" "sudo nut-scanner -U -q"
assert_contains "$RUN_OUTPUT" "No UPS found on USB"
[ -z "$(ls "$NUT_DIR")" ] || fail "NUT's config was written for a UPS nut-scanner didn't find"
[ ! -e "$UPS_NOTIFY" ] || fail "the notifier was installed for a UPS nut-scanner didn't find"
assert_file_not_contains "$STUB_LOG" "systemctl"
scan usbhid-ups 0764 0501
assert_contains "$(ups_todo)" "UPS: set up NUT for the UPS on USB (0764:0501)"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS on USB (0764:0501) monitored by NUT: not set up for it (re-run the ubuntu step)"
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_file_not_contains "$STUB_LOG" "apt-get"
# No POWEROFF_WAIT: systemd-shutdown kills its hooks after 90 s, so the RTC wake hook covers a
# UPS that doesn't cut its power
assert_eq "# From the dotfiles ubuntu step: upsd and upsmon run here, for this machine's own UPS
MODE=standalone" "$(cat "$NUT_DIR/nut.conf")" "nut.conf"
assert_eq '# From the dotfiles ubuntu step: the UPS nut-scanner found on USB
[ups]
	driver = "usbhid-ups"
	port = "auto"
	vendorid = "0764"
	productid = "0501"' "$(cat "$NUT_DIR/ups.conf")" "ups.conf"
assert_eq "# From the dotfiles ubuntu step: upsd answers only this machine
LISTEN 127.0.0.1" "$(cat "$NUT_DIR/upsd.conf")" "upsd.conf"
PASSWORD="$(sed -n 's/^[[:space:]]*password = //p' "$NUT_DIR/upsd.users")"
[ "${#PASSWORD}" -ge 24 ] || fail "upsmon's password is short: '$PASSWORD'"
assert_eq "# From the dotfiles ubuntu step: upsmon's login to upsd
[upsmon]
	password = $PASSWORD
	upsmon primary" "$(cat "$NUT_DIR/upsd.users")" "upsd.users"
assert_eq "# From the dotfiles ubuntu step: watch the UPS, push its events, and shut down on a low battery
MONITOR ups@localhost 1 upsmon $PASSWORD primary
SHUTDOWNCMD \"/sbin/shutdown -h +0\"
POWERDOWNFLAG /etc/killpower
NOTIFYCMD $UPS_NOTIFY
NOTIFYFLAG ONBATT SYSLOG+EXEC
NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG COMMOK SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC
NOTIFYFLAG REPLBATT SYSLOG+EXEC
NOTIFYFLAG NOCOMM SYSLOG+EXEC" "$(cat "$NUT_DIR/upsmon.conf")" "upsmon.conf"
# Each file is readable only by root and the nut group, as the packages ship them, since two hold
# upsmon's password
for file in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
    assert_eq 640 "$(file_mode "$NUT_DIR/$file")" "$file's mode"
    assert_file_contains "$STUB_LOG" "sudo chgrp nut $NUT_DIR/$file"
done
# The notifier and the ntfy code it runs, as root's, from outside the repo
cmp -s "$REPO_DIR/ubuntu/ups-notify.sh" "$UPS_NOTIFY" || fail "the notifier isn't the repo's"
[ -x "$UPS_NOTIFY" ] || fail "the notifier isn't executable"
cmp -s "$REPO_DIR/ubuntu/lib/ntfy.sh" "$NTFY_LIB" || fail "the notifier's ntfy code isn't the repo's"
assert_file_contains "$STUB_LOG" "sudo systemctl enable nut-server.service nut-monitor.service"
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver-enumerator.service"
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver@ups.service nut-server.service nut-monitor.service"
assert_contains "$RUN_OUTPUT" "NUT watches the UPS on USB (0764:0501)"
# The RTC wake hook, root's and executable, sets an alarm 15 minutes out only after a UPS shutdown
[ -x "$UPS_RTC_HOOK" ] || fail "the RTC wake hook isn't executable"
assert_eq "#!/bin/sh
# From the dotfiles ubuntu step: after a UPS shutdown, which leaves /etc/killpower, start the
# machine in 15 minutes in case the UPS doesn't cut its power
[ -e /etc/killpower ] || exit 0
exec /usr/sbin/rtcwake -m no -s 900" "$(cat "$UPS_RTC_HOOK")" "the RTC wake hook"
stub rtcwake
HOOK_COPY="$SANDBOX/rtc-hook-copy"
sed -e "s|/etc/killpower|$SANDBOX/killpower|g" -e "s|/usr/sbin/rtcwake|rtcwake|" "$UPS_RTC_HOOK" > "$HOOK_COPY"
: > "$STUB_LOG"
assert_exit 0 sh "$HOOK_COPY" poweroff
assert_file_not_contains "$STUB_LOG" "rtcwake"
touch "$SANDBOX/killpower"
assert_exit 0 sh "$HOOK_COPY" poweroff
assert_file_contains "$STUB_LOG" "rtcwake -m no -s 900"
rm "$SANDBOX/killpower"

# Set up: nothing to do, and status reports it, its state, and its charge
upsc_answers "OL CHRG" 0764 0501
assert_eq "" "$(ups_todo)" "what the UPS part needs once set up"
assert_exit 0 status_ups
assert_contains "$RUN_OUTPUT" "ok         UPS on USB (0764:0501) monitored by NUT"
assert_contains "$RUN_OUTPUT" "ok         UPS on mains power (ups.status OL CHRG)"
assert_contains "$RUN_OUTPUT" "info       UPS battery charge: 100%"
assert_contains "$RUN_OUTPUT" "ok         nut-server and nut-monitor running"
assert_contains "$RUN_OUTPUT" "ok         UPS events pushed to ntfy ($UPS_NOTIFY)"
assert_contains "$RUN_OUTPUT" "ok         RTC wake hook ($UPS_RTC_HOOK) installed: asks the board to start the machine 15 minutes after a UPS shutdown if the UPS keeps its power on; check once that your board wakes (see the Power cuts manual step)"
# On battery: information, not a problem
upsc_answers "OB DISCHRG" 0764 0501
run status_ups
assert_contains "$RUN_OUTPUT" "info       UPS status: OB DISCHRG (on battery)"
upsc_answers "OL" 0764 0501

# --- an unchanged second run ---
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_file_not_contains "$STUB_LOG" "install -m"
assert_file_not_contains "$STUB_LOG" "restart"
assert_contains "$RUN_OUTPUT" "already set up"
assert_eq "$PASSWORD" "$(sed -n 's/^[[:space:]]*password = //p' "$NUT_DIR/upsd.users")" "upsmon's password after a second run"

# A notifier out of date: the step reinstalls it, and nut-scanner finds the same UPS, so ups.conf
# stays as it is and NUT isn't restarted
echo "# edited" >> "$UPS_NOTIFY"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS events pushed to ntfy"
assert_contains "$(ups_todo)" "UPS: set up NUT"
UPS_CONF="$(cat "$NUT_DIR/ups.conf")"
: > "$STUB_LOG"
assert_exit 0 setup_ups
cmp -s "$REPO_DIR/ubuntu/ups-notify.sh" "$UPS_NOTIFY" || fail "the notifier wasn't reinstalled"
assert_eq "$UPS_CONF" "$(cat "$NUT_DIR/ups.conf")" "ups.conf after reinstalling the notifier"
assert_file_contains "$STUB_LOG" "sudo nut-scanner -U -q"
assert_file_not_contains "$STUB_LOG" "restart"

# NUT's files readable only with sudo, and sudo credentials not cached: status can't verify them,
# and the step doesn't ask for sudo only to read them, since upsd answers for the UPS
if [ "$(id -u)" -ne 0 ]; then
    touch "$SANDBOX/no-sudo"
    for file in "${NUT_FILES[@]}"; do
        chmod 000 "$NUT_DIR/$file"
        assert_exit 2 nut_files_current
        run status_ups
        assert_contains "$RUN_OUTPUT" "unverified UPS on USB (0764:0501) monitored by NUT: can't read NUT configuration files in $NUT_DIR without sudo; run sudo -v, then status, to check them"
        assert_eq "" "$(ups_todo)" "what the UPS part needs when $file can't be read"
        chmod 640 "$NUT_DIR/$file"
    done
    rm "$SANDBOX/no-sudo"
fi

# The RTC wake hook out of date: status says so, and the step replaces it alone
echo "# edited" >> "$UPS_RTC_HOOK"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    RTC wake hook ($UPS_RTC_HOOK): missing or out of date"
assert_contains "$(ups_todo)" "the RTC wake hook $UPS_RTC_HOOK"
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_eq "$(ups_rtc_hook)" "$(cat "$UPS_RTC_HOOK")" "the RTC wake hook after a re-run"
assert_contains "$RUN_OUTPUT" "Installed the RTC wake hook"
assert_file_not_contains "$STUB_LOG" "restart"
assert_exit 0 status_ups

# nut-monitor stopped while nut-server runs: not ready, and the step starts it
rm "$SANDBOX/active-nut-monitor.service"
assert_contains "$(ups_todo)" "UPS: set up NUT"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    nut-server and nut-monitor running"
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_file_contains "$STUB_LOG" "sudo systemctl start nut-server.service nut-monitor.service"
[ -e "$SANDBOX/active-nut-monitor.service" ] || fail "nut-monitor wasn't started"

# The files current and the services running, but upsd doesn't answer for the UPS, as when its
# driver stopped: the step restarts the driver and the services
rm "$SANDBOX/upsc"
assert_contains "$(ups_todo)" "UPS: set up NUT"
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver-enumerator.service"
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver@ups.service nut-server.service nut-monitor.service"
assert_not_contains "$RUN_OUTPUT" "already set up"
upsc_answers OL 0764 0501

# --- a changed UPS ---
unplug 1-3
usb_device 1-4 0463 ffff ups
scan usbhid-ups 0463 ffff
rm "$SANDBOX/upsc"
assert_contains "$(ups_todo)" "UPS: set up NUT for the UPS on USB (0463:ffff)"
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_file_contains "$NUT_DIR/ups.conf" 'vendorid = "0463"'
assert_file_contains "$NUT_DIR/ups.conf" 'productid = "ffff"'
assert_file_not_contains "$NUT_DIR/ups.conf" "0764"
assert_eq "$PASSWORD" "$(sed -n 's/^[[:space:]]*password = //p' "$NUT_DIR/upsd.users")" "upsmon's password after a new UPS"
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver-enumerator.service"
# Only ups.conf changed
assert_eq 1 "$(grep -c 'install -m 0640' "$STUB_LOG")" "files rewritten for a new UPS"
upsc_answers OL 0463 ffff
assert_eq "" "$(ups_todo)" "what the UPS part needs once set up for the new UPS"

# A UPS that's no longer plugged in keeps its config, and status says so
unplug 1-4
rm "$SANDBOX/upsc"
assert_eq "" "$(ups_todo)" "what the UPS part needs with the UPS unplugged"
run status_ups
assert_contains "$RUN_OUTPUT" "skipped    UPS monitored by NUT: no UPS on USB; plug in the UPS's USB cable and re-run the ubuntu step"

# --- NUT removed while a UPS is plugged in: the step installs it again ---
usb_device 1-4 0463 ffff ups
rm "$SANDBOX/nut-installed"
assert_contains "$(ups_todo)" "UPS: install nut-client and nut-server"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS on USB (0463:ffff) monitored by NUT: nut-client and nut-server aren't installed"
: > "$STUB_LOG"
assert_exit 0 setup_ups
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y nut-client nut-server"

# --- no upower hwdb, or no udev database: status can't tell, and the step installs nothing ---
mv "$UPOWER_HWDB" "$UPOWER_HWDB.gone"
assert_eq "" "$(ups_todo)" "what the UPS part needs without upower's hwdb"
run status_ups
assert_contains "$RUN_OUTPUT" "unknown    UPS monitored by NUT: can't tell whether a UPS is on USB, since $UPOWER_HWDB is missing; install upower"
run warn_no_ups
assert_contains "$RUN_OUTPUT" "$UPOWER_HWDB is missing"
mv "$UPOWER_HWDB.gone" "$UPOWER_HWDB"
touch "$SANDBOX/udev-fails"
assert_eq "" "$(ups_todo)" "what the UPS part needs when udevadm fails"
run status_ups
assert_contains "$RUN_OUTPUT" "unknown    UPS monitored by NUT: can't tell whether a UPS is on USB, since udevadm info --export-db failed"
rm "$SANDBOX/udev-fails"

# --- a VM ---
stub systemd-detect-virt
assert_eq "" "$(ups_todo)" "what the UPS part needs in a VM"
run status_ups
assert_contains "$RUN_OUTPUT" "skipped    UPS monitored by NUT: this is a VM"
stub systemd-detect-virt 'exit 1'

# --- the notifier ---
URL_FILE="$SANDBOX/ntfy-url"
NOTIFY="$SANDBOX/ups-notify.sh"
ntfy_hook_copy ubuntu/ups-notify.sh "$URL_FILE" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$NOTIFY"
stub curl 'case " $* " in *" -K - "*) sed "s/^/curl config: /" >> "$STUB_LOG" ;; esac
[ ! -e "'"$SANDBOX"'/curl-fails" ] || { echo "curl: (6) Could not resolve host: ntfy.sh" >&2; exit 6; }'
stub logger
notify() {
    : > "$STUB_LOG"
    assert_exit 0 env NOTIFYTYPE="$1" UPSNAME=ups@localhost "$BASH" "$NOTIFY" "$2"
}

# No URL saved: nothing pushed
notify ONBATT "UPS ups@localhost on battery"
assert_file_not_contains "$STUB_LOG" "curl"

# A URL saved: each event is pushed, the URL on stdin, and urgent for a low battery or a shutdown
echo "https://ntfy.sh/secret-topic" > "$URL_FILE"
notify ONBATT "UPS ups@localhost on battery"
assert_file_contains "$STUB_LOG" "-H Title: UPS on battery on $(hostname) -H Priority: high -H Tags: electric_plug --data-raw UPS ups@localhost on battery -K -"
assert_file_contains "$STUB_LOG" 'curl config: url = "https://ntfy.sh/secret-topic"'
notify ONLINE "UPS ups@localhost on line power"
assert_file_contains "$STUB_LOG" "-H Title: UPS on mains power on $(hostname) -H Priority: default -H Tags: white_check_mark --data-raw UPS ups@localhost on line power -K -"
notify LOWBATT "UPS ups@localhost battery is low"
assert_file_contains "$STUB_LOG" "-H Priority: urgent"
notify SHUTDOWN "Auto logout and shutdown proceeding"
assert_file_contains "$STUB_LOG" "-H Title: Shutting down on UPS battery on $(hostname) -H Priority: urgent"
notify REPLBATT "UPS ups@localhost battery needs to be replaced"
assert_file_contains "$STUB_LOG" "-H Priority: high"
if grep '^curl -' "$STUB_LOG" | grep -q secret-topic; then
    fail "curl's arguments name the ntfy topic"
fi

# curl failing: logged without the topic, and the notifier still exits 0
touch "$SANDBOX/curl-fails"
notify COMMBAD "Communications with UPS ups@localhost lost"
assert_file_contains "$STUB_LOG" "logger -t dotfiles-ups -- couldn't push the UPS event to ntfy: curl: (6) Could not resolve host: ntfy.sh"
if grep '^logger' "$STUB_LOG" | grep -q secret-topic; then
    fail "the log names the ntfy topic"
fi
rm "$SANDBOX/curl-fails"

# Without its ntfy code, it logs that and exits 0
ntfy_hook_copy ubuntu/ups-notify.sh "$URL_FILE" "$SANDBOX/no-ntfy.sh" "$NOTIFY"
notify ONBATT "UPS ups@localhost on battery"
assert_file_contains "$STUB_LOG" "logger -t dotfiles-ups -- couldn't push the UPS event to ntfy: $SANDBOX/no-ntfy.sh is missing"
test_done
