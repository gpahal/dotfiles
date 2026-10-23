#!/bin/bash

# lib/systemd.sh: unit checks, installing a system unit, the user manager's reachability, and
# starting and reporting a user service, against stub_systemctl_units.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script lib/common.sh
load_script lib/system.sh
load_script lib/gnome.sh
load_script lib/systemd.sh
STATE="$SANDBOX/units"
stub_systemctl_units "$STATE" '[ "$*" != "--user is-active --quiet graphical-session.target" ] || { [ -n "${SESSION:-}" ]; exit; }'
stub_sudo_exec

# --- unit_on and unit_enabled: every unit, system or user ---
assert_exit 1 unit_on docker.socket
touch "$STATE/docker.socket.enabled"
assert_exit 1 unit_on docker.socket
assert_exit 0 unit_enabled docker.socket
touch "$STATE/docker.socket.active"
assert_exit 0 unit_on docker.socket
assert_exit 1 unit_on docker.socket docker.service
assert_exit 1 unit_on --user docker.socket
touch "$STATE/user-tmux.service.enabled"
assert_exit 0 unit_enabled --user tmux.service
assert_exit 1 unit_enabled tmux.service
# As an item check string
items_reset
item "docker.socket on" "Turn on docker.socket" "unit_on docker.socket" :
assert_exit 0 items_ok

# --- enable_units_now ---
assert_exit 0 enable_units_now a.service b.timer
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now a.service b.timer"
assert_exit 0 unit_on a.service b.timer

# --- install_root_unit: installs it 0644, then reloads systemd ---
echo "[Service]" > "$SANDBOX/a.service"
chmod 755 "$SANDBOX/a.service"
assert_exit 0 install_root_unit "$SANDBOX/a.service" "$SANDBOX/etc/systemd/system/a.service"
assert_eq "[Service]" "$(cat "$SANDBOX/etc/systemd/system/a.service")" "the installed unit"
assert_eq 644 "$(file_mode "$SANDBOX/etc/systemd/system/a.service")" "the installed unit's mode"
assert_file_contains "$STUB_LOG" "sudo systemctl daemon-reload"
touch "$STATE/reload-fails"
assert_exit 1 install_root_unit "$SANDBOX/a.service" "$SANDBOX/etc/systemd/system/a.service"
rm "$STATE/reload-fails"

# --- unit_loaded_current: loaded, and no reload pending ---
assert_exit 0 unit_loaded_current --user a.service b.service
touch "$STATE/user-b.service.not-found"
assert_exit 1 unit_loaded_current --user a.service b.service
assert_exit 0 unit_loaded_current b.service
rm "$STATE/user-b.service.not-found"
touch "$STATE/reload-needed"
assert_exit 1 unit_loaded_current --user a.service

# --- user_manager_reachable ---
assert_exit 0 user_manager_reachable "tmux doesn't start at boot"
assert_eq "" "$RUN_OUTPUT" "user_manager_reachable's output with a manager"
touch "$STATE/no-user-manager"
assert_exit 1 user_manager_reachable "tmux doesn't start at boot"
assert_eq "  Couldn't reach your systemd user manager, so tmux doesn't start at boot yet.
  Re-run the step after the next reboot or login." "$RUN_OUTPUT" "user_manager_reachable's message"
assert_exit 1 user_manager_reachable "user services don't get Homebrew on PATH" \
    "They get it after the next reboot or login."
assert_eq "  Couldn't reach your systemd user manager, so user services don't get Homebrew on PATH yet.
  They get it after the next reboot or login." "$RUN_OUTPUT" "user_manager_reachable's message with its own next step"
rm "$STATE/no-user-manager"

# --- start_user_service: reload when changed or not loaded, enable, then start or restart ---
rm -f "$STATE/reload-needed"
touch "$STATE/user-deck.service.not-found"
assert_exit 0 start_user_service deck.service "the Stream Deck daemon" false
assert_eq "  No desktop session, so the Stream Deck daemon starts at your next login." "$RUN_OUTPUT" \
    "start_user_service without a desktop session"
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
assert_exit 0 unit_enabled --user deck.service
assert_exit 1 unit_active --user deck.service
export SESSION=1
assert_exit 0 start_user_service deck.service "the Stream Deck daemon" false
assert_file_not_contains "$STUB_LOG" "daemon-reload"
assert_file_not_contains "$STUB_LOG" "--user enable"
assert_eq "  Started the Stream Deck daemon." "$RUN_OUTPUT" "start_user_service with the service stopped"
assert_exit 0 start_user_service deck.service "the Stream Deck daemon" false
assert_eq "  The Stream Deck daemon is already running." "$RUN_OUTPUT" "start_user_service with the service running"
assert_eq "" "$(grep -v ' is-\| show' "$STUB_LOG")" "commands start_user_service ran with nothing to do"
assert_exit 0 start_user_service deck.service Vicinae true
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
assert_file_contains "$STUB_LOG" "systemctl --user restart deck.service"
assert_eq "  Restarted Vicinae." "$RUN_OUTPUT" "start_user_service after a change"
touch "$STATE/reload-fails"
assert_exit 1 start_user_service deck.service Vicinae true
assert_file_not_contains "$STUB_LOG" "restart deck.service"
rm "$STATE/reload-fails"

# --- status_user_service ---
assert_exit 0 status_user_service deck.service "Stream Deck daemon"
assert_eq "  ok         Stream Deck daemon starts at login
  ok         Stream Deck daemon running" "$RUN_OUTPUT" "status_user_service with the service running"
rm "$STATE/user-deck.service.active" "$STATE/user-deck.service.enabled"
run status_user_service deck.service "Stream Deck daemon"
assert_eq "  missing    Stream Deck daemon starts at login
  missing    Stream Deck daemon running: journalctl --user -u deck.service says why it stopped" "$RUN_OUTPUT" \
    "status_user_service with the service stopped"
unset SESSION
run status_user_service deck.service "Stream Deck daemon"
assert_contains "$RUN_OUTPUT" "unverified Stream Deck daemon running: no desktop session; it starts at the next login"

test_done
