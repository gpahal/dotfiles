#!/bin/bash
# shellcheck disable=SC2329

# The ubuntu step's UPS part (ubuntu/lib/ups.sh): NUT set up only for a UPS on USB, its config's
# password and permissions, and re-runs as the UPS or NUT changes.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

load_script ubuntu/install.sh
ubuntu_sandbox_paths
as_os ubuntu

file_group() { owner_group_mode "$1" | awk '{ print $2 }'; }
mkdir -p "$NUT_DIR" "$SANDBOX/udev"
touch "$UPOWER_HWDB"

stub udevadm '[ "$1 $2" == "info --export-db" ] || exit 0
[ ! -e "$SANDBOX/udev-fails" ] || exit 1
for f in "$SANDBOX"/udev/*; do [ ! -e "$f" ] || { cat "$f"; echo; }; done'
# upower's hwdb tags a UPS's hiddev child too, without the IDs
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
usb_device usb1 1d6b 0002
usb_device 1-2 046d c52b

stub_sudo_cacheable
cache_sudo yes
# The real one warns on stderr about missing optional libraries even when it succeeds
stub nut-scanner 'echo "Cannot load XML library (libneon-gnutls.so.27) : file not found. XML search disabled." >&2
[ ! -e "$SANDBOX/scan-fails" ] || { echo "Error: libusb_init() failed" >&2; exit 42; }
cat "$SANDBOX/scan" 2> /dev/null || true'
# NUT 2.8.2 and later name alternative drivers in a trailing comment
ups_scan() {
    printf '%s\n' "[nutdev-usb1]" "	driver = \"$1\"	# alternately: apc_modbus" '	port = "auto"' "	vendorid = \"$2\"" \
        "	productid = \"$3\"" '	product = "CP1500PFCLCD"' '	serial = "CXXNV2000123"' '	vendor = "CPS"' \
        '	# bus = "001"' '	# device = "004"' '	# busport = "002"' > "$SANDBOX/scan"
}
stub dpkg-query 'case "${!#}" in
    nut-client | nut-server) [ -e "$SANDBOX/nut-installed" ] && echo "install ok installed" ;;
    *) echo "install ok installed" ;;
esac'
stub apt-get '[[ " $* " != *" install "* ]] || touch "$SANDBOX/nut-installed"'
stub upsc '[ -e "$SANDBOX/upsc" ] || { echo "Error: Driver not connected" >&2; exit 1; }
sed -n "s/^$2: //p" "$SANDBOX/upsc"'
upsc_answers() {
    printf '%s\n' "ups.status: $1" "battery.charge: 100" "ups.vendorid: $2" "ups.productid: $3" > "$SANDBOX/upsc"
}
stub systemctl 'cmd="$1"
shift
case "$cmd" in
    is-active)
        [ "$1" != -q ] || shift
        for unit in "$@"; do [ ! -e "$SANDBOX/active-$unit" ] || exit 0; done
        exit 3 ;;
    restart | start) for unit in "$@"; do touch "$SANDBOX/active-$unit"; done ;;
    is-enabled) [ ! -e "$SANDBOX/disabled-${!#}" ] ;;
    enable) for unit in "$@"; do rm -f "$SANDBOX/disabled-$unit"; done ;;
esac'
stub systemd-detect-virt 'exit 1'

# --- no UPS on USB ---
assert_eq "" "$(ups_todo)" "what the UPS part needs with no UPS on USB"
assert_exit 0 status_ups
[ ! -e "$SANDBOX/nut-installed" ] || fail "NUT was installed without a UPS"

# --- a UPS plugged in on a later run ---
usb_device 1-3 0764 0501 ups
assert_contains "$(ups_todo)" "UPS: install nut-client and nut-server, and set up NUT for the UPS on USB (0764:0501)"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS on USB (0764:0501) monitored by NUT: nut-client and nut-server aren't installed (re-run the ubuntu step)"
assert_exit 0 setup_ups
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y nut-client nut-server"
assert_file_contains "$STUB_LOG" "sudo udevadm trigger --settle --subsystem-match=usb --action=change"
assert_file_contains "$STUB_LOG" "sudo nut-scanner -U -q"
assert_contains "$RUN_OUTPUT" "No UPS found on USB"
[ -z "$(ls "$NUT_DIR")" ] || fail "NUT's config was written for a UPS nut-scanner didn't find"
[ ! -e "$UPS_NOTIFY" ] || fail "the notifier was installed for a UPS nut-scanner didn't find"
assert_file_not_contains "$STUB_LOG" "systemctl"
assert_not_contains "$RUN_OUTPUT" "Cannot load XML library"
# A scan that fails, unlike one that finds nothing, fails the step and shows nut-scanner's stderr
touch "$SANDBOX/scan-fails"
TMP_FILES="$(ls "$TMPDIR")"
assert_exit 1 setup_ups
assert_contains "$RUN_OUTPUT" "  nut-scanner -U failed (exit 42), so NUT isn't set up:
    Cannot load XML library (libneon-gnutls.so.27) : file not found. XML search disabled.
    Error: libusb_init() failed"
assert_not_contains "$RUN_OUTPUT" "No UPS found"
assert_eq "" "$(setup_ups 2> /dev/null)" "setup_ups's stdout when nut-scanner fails"
assert_eq "$TMP_FILES" "$(ls "$TMPDIR")" "temp files after a failed scan"
[ -z "$(ls "$NUT_DIR")" ] || fail "NUT's config was written after nut-scanner failed"
assert_file_not_contains "$STUB_LOG" "systemctl"
rm "$SANDBOX/scan-fails"
ups_scan usbhid-ups 0764 0501
assert_contains "$(ups_todo)" "UPS: set up NUT for the UPS on USB (0764:0501)"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS on USB (0764:0501) monitored by NUT: not set up for it (re-run the ubuntu step)"
assert_exit 0 setup_ups
assert_file_not_contains "$STUB_LOG" "apt-get"
# upsd answers only this machine, for the UPS found, and upsmon shuts down on a low battery
assert_file_contains "$NUT_DIR/upsd.conf" "LISTEN 127.0.0.1"
assert_file_contains "$NUT_DIR/ups.conf" 'vendorid = "0764"'
assert_file_contains "$NUT_DIR/ups.conf" 'productid = "0501"'
upsmon_password() { nut_value password < "$NUT_DIR/upsd.users"; }
PASSWORD="$(upsmon_password)"
[ "${#PASSWORD}" -ge 24 ] || fail "upsmon's password is short: '$PASSWORD'"
assert_file_contains "$NUT_DIR/upsmon.conf" "MONITOR ups@localhost 1 upsmon \"$PASSWORD\" primary"
assert_file_contains "$NUT_DIR/upsmon.conf" 'SHUTDOWNCMD "/sbin/shutdown -h +0"'
assert_file_contains "$NUT_DIR/upsmon.conf" "POWERDOWNFLAG /etc/killpower"
assert_file_contains "$NUT_DIR/upsmon.conf" "NOTIFYCMD $UPS_NOTIFY"
# Root and the nut group only, since two files hold upsmon's password
for file in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
    assert_eq 640 "$(file_mode "$NUT_DIR/$file")" "$file's mode"
    assert_eq "$NUT_GROUP" "$(file_group "$NUT_DIR/$file")" "$file's group"
done
assert_eq 5 "$(grep -c "install -m 0640 -g $NUT_GROUP " "$STUB_LOG")" "NUT's files installed with their group"
assert_file_not_contains "$STUB_LOG" "chgrp"
[ -x "$UPS_NOTIFY" ] || fail "the notifier isn't executable"
assert_file_contains "$STUB_LOG" "sudo systemctl enable nut.target nut-server.service nut-monitor.service"
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver-enumerator.service"
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver@ups.service nut-server.service nut-monitor.service"
assert_contains "$RUN_OUTPUT" "NUT watches the UPS on USB (0764:0501)"
[ -x "$UPS_RTC_HOOK" ] || fail "the RTC wake hook isn't executable"
# No POWEROFF_WAIT: systemd-shutdown kills hooks after 90 s, so the RTC wake hook covers a UPS
# that keeps power. It acts only after a UPS shutdown, which leaves /etc/killpower.
stub rtcwake
HOOK_COPY="$SANDBOX/rtc-hook-copy"
sed -e "s|/etc/killpower|$SANDBOX/killpower|g" -e "s|/usr/sbin/rtcwake|rtcwake|" "$UPS_RTC_HOOK" > "$HOOK_COPY"
assert_exit 0 sh "$HOOK_COPY" poweroff
assert_file_not_contains "$STUB_LOG" "rtcwake"
touch "$SANDBOX/killpower"
assert_exit 0 sh "$HOOK_COPY" poweroff
assert_file_contains "$STUB_LOG" "rtcwake -m no -s 900"
rm "$SANDBOX/killpower"

upsc_answers "OL CHRG" 0764 0501
assert_eq "" "$(ups_todo)" "what the UPS part needs once set up"
assert_exit 0 status_ups
upsc_answers "OL" 0764 0501

# --- an unchanged second run ---
assert_exit 0 setup_ups
assert_file_not_contains "$STUB_LOG" "install -m"
assert_file_not_contains "$STUB_LOG" "restart"
assert_contains "$RUN_OUTPUT" "already set up"
assert_eq "$PASSWORD" "$(upsmon_password)" "upsmon's password after a second run"

# An outdated notifier is reinstalled without restarting NUT
echo "# edited" >> "$UPS_NOTIFY"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS events pushed to ntfy"
assert_contains "$(ups_todo)" "UPS: set up NUT"
UPS_CONF="$(cat "$NUT_DIR/ups.conf")"
assert_exit 0 setup_ups
cmp -s "$REPO_DIR/ubuntu/ups-notify.sh" "$UPS_NOTIFY" || fail "the notifier wasn't reinstalled"
assert_eq "$UPS_CONF" "$(cat "$NUT_DIR/ups.conf")" "ups.conf after reinstalling the notifier"
assert_file_contains "$STUB_LOG" "sudo nut-scanner -U -q"
assert_file_not_contains "$STUB_LOG" "restart"

# Without cached sudo, an unreadable file is unverified; the step won't ask for sudo just to read it
if [ "$(id -u)" -ne 0 ]; then
    cache_sudo no
    chmod 000 "$NUT_DIR/upsd.users"
    assert_exit 2 nut_files_current
    run status_ups
    assert_contains "$RUN_OUTPUT" "unverified UPS on USB (0764:0501) monitored by NUT: can't read NUT configuration files in $NUT_DIR without sudo; run sudo -v, then status, to check them"
    assert_eq "" "$(ups_todo)" "what the UPS part needs when upsd.users can't be read"
    chmod 640 "$NUT_DIR/upsd.users"
    cache_sudo yes
else
    echo "Skipped the unreadable NUT file case: root reads any file"
fi

# --- one thing broken at a time ---
# A test can't chown or chgrp to another user or group, so $SANDBOX/upsmon-meta stands in for
# upsmon.conf's owner, group, and mode until the step rewrites it
wrap_fn owner_group_mode 'if [ "$1" == "$NUT_DIR/upsmon.conf" ] && [ -e "$SANDBOX/upsmon-meta" ]; then
    cat "$SANDBOX/upsmon-meta"
else
    real_owner_group_mode "$@"
fi'
NOT_SET_UP="UPS on USB (0764:0501) monitored by NUT: not set up for it (re-run the ubuntu step)"
# broken <break> <undo after the re-run> <status line> <in the re-run's log> <in its output>
#   <NUT files rewritten>
broken() {
    eval "$1"
    assert_contains "$(ups_todo)" "UPS: set up NUT" "what the UPS part needs after: $1"
    if [ -n "$3" ]; then
        run status_ups
        assert_contains "$RUN_OUTPUT" "missing    $3"
    fi
    assert_exit 0 setup_ups
    [ -z "$4" ] || assert_file_contains "$STUB_LOG" "$4"
    [ -z "$5" ] || assert_contains "$RUN_OUTPUT" "$5"
    assert_not_contains "$RUN_OUTPUT" "already set up"
    assert_eq "$6" "$(grep -c 'install -m 0640' "$STUB_LOG")" "NUT files rewritten after: $1"
    eval "$2"
    assert_eq "" "$(ups_todo)" "what the UPS part needs after re-running for: $1"
}
# A wrong owner or group, as a failed chown or chgrp leaves it: only that file is rewritten
broken 'echo "nobody $NUT_GROUP 640" > "$SANDBOX/upsmon-meta"' 'rm "$SANDBOX/upsmon-meta"' "$NOT_SET_UP" \
    "$NUT_DIR/upsmon.conf" "" 1
broken 'echo "$NUT_OWNER other 640" > "$SANDBOX/upsmon-meta"' 'rm "$SANDBOX/upsmon-meta"' "$NOT_SET_UP" \
    "$NUT_DIR/upsmon.conf" "" 1
# 0644 and 0666 leak the password, 0600 locks out the nut group
for mode in 644 666 600; do
    broken "chmod $mode \"\$NUT_DIR/upsd.users\"" "" "$NOT_SET_UP" "" "" 1
    assert_eq 640 "$(file_mode "$NUT_DIR/upsd.users")" "upsd.users's mode after a re-run from $mode"
done
broken 'echo "# edited" >> "$UPS_RTC_HOOK"' "" "RTC wake hook ($UPS_RTC_HOOK): missing or out of date" \
    "" "Installed the RTC wake hook" 0
assert_eq "$(ups_rtc_hook)" "$(cat "$UPS_RTC_HOOK")" "the RTC wake hook after a re-run"
broken 'rm "$SANDBOX/active-nut-monitor.service"' "" "nut-server and nut-monitor running" \
    "sudo systemctl start nut-server.service nut-monitor.service" "" 0
# NUT wouldn't start after a reboot
broken 'touch "$SANDBOX/disabled-nut.target"' "" "nut.target enabled, so NUT starts at boot" \
    "" "Enabled nut.target, so NUT starts at boot." 0
# upsd not answering, as when its driver stopped
broken 'rm "$SANDBOX/upsc"' 'upsc_answers OL 0764 0501' "" \
    "sudo systemctl restart nut-driver@ups.service nut-server.service nut-monitor.service" "" 0

# A symlink counts by its target's owner, group, and mode
mv "$NUT_DIR/upsd.users" "$SANDBOX/upsd.users"
ln -s "$SANDBOX/upsd.users" "$NUT_DIR/upsd.users"
assert_exit 0 nut_files_current
rm "$NUT_DIR/upsd.users"
mv "$SANDBOX/upsd.users" "$NUT_DIR/upsd.users"

# --- a changed UPS ---
unplug 1-3
usb_device 1-4 0463 ffff ups
ups_scan usbhid-ups 0463 ffff
rm "$SANDBOX/upsc"
assert_contains "$(ups_todo)" "UPS: set up NUT for the UPS on USB (0463:ffff)"
assert_exit 0 setup_ups
assert_file_contains "$NUT_DIR/ups.conf" 'vendorid = "0463"'
assert_file_contains "$NUT_DIR/ups.conf" 'productid = "ffff"'
assert_file_not_contains "$NUT_DIR/ups.conf" "0764"
assert_eq "$PASSWORD" "$(upsmon_password)" "upsmon's password after a new UPS"
assert_file_contains "$STUB_LOG" "sudo systemctl restart nut-driver-enumerator.service"
assert_eq 1 "$(grep -c 'install -m 0640' "$STUB_LOG")" "files rewritten for a new UPS"
upsc_answers OL 0463 ffff
assert_eq "" "$(ups_todo)" "what the UPS part needs once set up for the new UPS"

unplug 1-4
rm "$SANDBOX/upsc"
assert_eq "" "$(ups_todo)" "what the UPS part needs with the UPS unplugged"
run status_ups
assert_contains "$RUN_OUTPUT" "skipped    UPS monitored by NUT: no UPS on USB; plug in the UPS's USB cable and re-run the ubuntu step"

# --- NUT removed while a UPS is plugged in ---
usb_device 1-4 0463 ffff ups
rm "$SANDBOX/nut-installed"
assert_contains "$(ups_todo)" "UPS: install nut-client and nut-server"
run status_ups
assert_contains "$RUN_OUTPUT" "missing    UPS on USB (0463:ffff) monitored by NUT: nut-client and nut-server aren't installed"
assert_exit 0 setup_ups
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y nut-client nut-server"

# --- no upower hwdb, or no udev database ---
mv "$UPOWER_HWDB" "$UPOWER_HWDB.gone"
assert_eq "" "$(ups_todo)" "what the UPS part needs without upower's hwdb"
run status_ups
assert_contains "$RUN_OUTPUT" "info       UPS monitored by NUT: can't tell whether a UPS is on USB: $UPOWER_HWDB is missing (install upower), or udevadm info --export-db failed"
run warn_no_ups
assert_contains "$RUN_OUTPUT" "$UPOWER_HWDB is missing"
mv "$UPOWER_HWDB.gone" "$UPOWER_HWDB"
touch "$SANDBOX/udev-fails"
assert_eq "" "$(ups_todo)" "what the UPS part needs when udevadm fails"
run status_ups
assert_contains "$RUN_OUTPUT" "info       UPS monitored by NUT: can't tell whether a UPS is on USB"
rm "$SANDBOX/udev-fails"

# --- a VM ---
stub systemd-detect-virt
assert_eq "" "$(ups_todo)" "what the UPS part needs in a VM"
run status_ups
assert_contains "$RUN_OUTPUT" "skipped    UPS monitored by NUT: this is a VM"
stub systemd-detect-virt 'exit 1'

test_done
