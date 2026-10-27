#!/bin/bash
# shellcheck disable=SC2329
# os: ubuntu

# The monitor-volume step, and dotfiles-monitor-volume, which its service and the volume keys run:
# handing GNOME's volume keys over while the monitor is the sound output and back once it isn't,
# DDC/CI volume with software volume when the monitor doesn't answer, and presses during a slow
# write landing in one.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v flock &> /dev/null || skip "flock isn't installed"
STATE="$SANDBOX/state"
export STATE
stub_gnome_session "$STATE"
# The default sink's node.name, from $SANDBOX/sink
stub wpctl '[ "$1" != inspect ] || printf "id 61, type PipeWire:Interface:Node\n  * node.name = \"%s\"\n" "$(cat "$SANDBOX/sink")"'
# A monitor at $SANDBOX/level of 100, which doesn't answer while $SANDBOX/ddc-fails exists
stub ddcutil '[ ! -e "$SANDBOX/ddc-fails" ] || exit 1
case "$*" in
    "getvcp 62 --brief") echo "VCP 62 C $(cat "$SANDBOX/level") 100" ;;
    "--noverify setvcp 62 "*) echo "$4" > "$SANDBOX/level" ;;
esac'
stub notify-send 'echo 7'
stub pw-metadata
HDMI=alsa_output.pci-0000_0c_00.1.hdmi-stereo
USB=alsa_output.usb-Generic_USB_DAC-00.analog-stereo
echo "$HDMI" > "$SANDBOX/sink"
echo 40 > "$SANDBOX/level"

MEDIA=org.gnome.settings-daemon.plugins.media-keys
DIR=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
SCRIPT="$REPO_DIR/monitor-volume/dotfiles-monitor-volume"
export MONITOR_VOLUME_STATE_DIR="$SANDBOX/run" MONITOR_VOLUME_SETTLE=0
gs() { gsettings get "$@"; }
user_shortcut
# GNOME's defaults
gsettings set "$MEDIA" volume-up-static "['XF86AudioRaiseVolume', '<Ctrl>XF86AudioRaiseVolume']"
gsettings set "$MEDIA" volume-down-static "['XF86AudioLowerVolume', '<Ctrl>XF86AudioLowerVolume']"
gsettings set "$MEDIA" volume-step 6
# One of yours on GNOME's volume-down
gsettings set "$MEDIA" volume-down "['<Super>F11']"

volume() {
    run bash "$SCRIPT" "$@"
}

the_script() {
    # The monitor gets the plain keys; GNOME keeps Ctrl's, and your shortcuts stay
    volume sync
    assert_eq 0 "$RUN_STATUS" "sync's status"
    assert_contains "$RUN_OUTPUT" "The monitor is the sound output, so the volume keys set its volume."
    assert_eq "['<Ctrl>XF86AudioRaiseVolume']" "$(gs "$MEDIA" volume-up-static)" "GNOME's up keys"
    assert_eq "['<Ctrl>XF86AudioLowerVolume']" "$(gs "$MEDIA" volume-down-static)" "GNOME's down keys"
    # GNOME re-reads a static binding only when its key changes, and the key keeps your value
    assert_file_contains "$STUB_LOG" "gsettings set $MEDIA volume-up @as []"
    assert_file_contains "$STUB_LOG" "gsettings set $MEDIA volume-down ['<Super>F11']"
    assert_eq "['$DIR/custom0/', '$DIR/dotfiles-monitor-volume-up/', '$DIR/dotfiles-monitor-volume-down/']" \
        "$(gs "$MEDIA" custom-keybindings)" "the shortcut list"
    assert_eq "'XF86AudioRaiseVolume'" "$(gs "$MEDIA.custom-keybinding:$DIR/dotfiles-monitor-volume-up/" binding)" "the up shortcut"
    assert_eq "\"systemd-cat -t dotfiles-monitor-volume '$SCRIPT' down\"" \
        "$(gs "$MEDIA.custom-keybinding:$DIR/dotfiles-monitor-volume-down/" command)" "the down shortcut's command"
    volume sync
    assert_file_not_contains "$STUB_LOG" "gsettings set"

    # The shortcut's command splits as a shell would, and runs the script
    stub systemd-cat 'shift 2; exec "$@"'
    cmd="$(gs "$MEDIA.custom-keybinding:$DIR/dotfiles-monitor-volume-up/" command)"
    cmd="${cmd#\"}"
    run eval "${cmd%\"}"
    assert_eq 46 "$(cat "$SANDBOX/level")" "the monitor's volume after up"
    assert_file_contains "$STUB_LOG" "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0"
    assert_file_contains "$STUB_LOG" "notify-send --transient --print-id --replace-id=0 --app-name=Monitor volume --icon=audio-volume-high-symbolic Monitor volume 46"

    # Down doesn't unmute, the notification replaces the last, and the volume stops at 0 and 100
    volume down
    assert_eq 40 "$(cat "$SANDBOX/level")" "the monitor's volume after down"
    assert_file_not_contains "$STUB_LOG" "set-mute"
    assert_file_contains "$STUB_LOG" "--replace-id=7"
    echo 3 > "$SANDBOX/level"
    volume down
    assert_eq 0 "$(cat "$SANDBOX/level")" "the monitor's volume after down at 3"
    echo 98 > "$SANDBOX/level"
    volume up
    assert_eq 100 "$(cat "$SANDBOX/level")" "the monitor's volume after up at 98"

    # Presses while another holds the worker lock wait for it, then land in one write
    echo 40 > "$SANDBOX/level"
    mkdir -p "$SANDBOX/run"
    exec 9> "$SANDBOX/run/worker.lock"
    flock 9
    volume up
    volume up
    assert_file_not_contains "$STUB_LOG" "ddcutil"
    assert_eq 40 "$(cat "$SANDBOX/level")" "the monitor's volume while the lock is held"
    exec 9>&-
    volume down
    assert_eq 46 "$(cat "$SANDBOX/level")" "the monitor's volume after up, up, and down"
    assert_eq 1 "$(grep -c "setvcp" "$STUB_LOG")" "the writes for three presses"

    # A monitor that doesn't answer, as on another input, gets software volume
    touch "$SANDBOX/ddc-fails"
    volume up
    assert_contains "$RUN_OUTPUT" "The monitor didn't answer over DDC/CI"
    assert_file_contains "$STUB_LOG" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 6%+"
    volume down
    assert_file_contains "$STUB_LOG" "wpctl set-volume @DEFAULT_AUDIO_SINK@ 6%-"
    rm "$SANDBOX/ddc-fails"

    # Another output gets GNOME's keys back, with the shortcuts cleared, and GNOME's step
    echo "$USB" > "$SANDBOX/sink"
    volume sync
    assert_contains "$RUN_OUTPUT" "The sound output isn't the monitor, so GNOME has the volume keys."
    assert_eq "['XF86AudioRaiseVolume', '<Ctrl>XF86AudioRaiseVolume']" "$(gs "$MEDIA" volume-up-static)" "GNOME's up keys back"
    assert_eq "''" "$(gs "$MEDIA.custom-keybinding:$DIR/dotfiles-monitor-volume-up/" binding)" "the up shortcut, cleared"
    volume sync
    assert_file_not_contains "$STUB_LOG" "gsettings set"
    gsettings set "$MEDIA" volume-step 3
    volume up
    assert_file_contains "$STUB_LOG" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 3%+"
    assert_file_not_contains "$STUB_LOG" "ddcutil"
    gsettings set "$MEDIA" volume-step 6

    # watch syncs at the start and on each change to the default sink, then fails when
    # pw-metadata ends, so the service restarts it; release hands the keys back
    echo "$HDMI" > "$SANDBOX/sink"
    stub pw-metadata 'echo "update: id:0 key:'"'default.audio.source'"' value:x"
echo "$USB" > "$SANDBOX/sink"
echo "update: id:0 key:'"'default.audio.sink'"' value:x"'
    volume watch
    assert_eq 1 "$RUN_STATUS" "watch's status when pw-metadata ends"
    assert_eq "The monitor is the sound output, so the volume keys set its volume.
The sound output isn't the monitor, so GNOME has the volume keys.
pw-metadata stopped." "$RUN_OUTPUT" "watch's output"
    echo "$HDMI" > "$SANDBOX/sink"
    volume sync
    volume release
    assert_eq "['XF86AudioLowerVolume', '<Ctrl>XF86AudioLowerVolume']" "$(gs "$MEDIA" volume-down-static)" "GNOME's down keys after release"
    assert_eq "''" "$(gs "$MEDIA.custom-keybinding:$DIR/dotfiles-monitor-volume-down/" binding)" "the down shortcut after release"

    volume bogus
    assert_eq 2 "$RUN_STATUS" "a bad command's status"
}
subtest the_script

the_step() {
    local script="$HOME/.local/share/dotfiles/monitor-volume/dotfiles-monitor-volume"
    local unit="$HOME/.config/systemd/user/dotfiles-monitor-volume.service"
    stub_sudo_exec
    stub_apt_packages
    load_script monitor-volume/install.sh
    as_os ubuntu
    # shellcheck disable=SC2034 # apt_get_update reads it
    APT_UPDATE_RETRY_DELAY=0
    export SESSION=1

    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    ddcutil"
    assert_contains "$RUN_OUTPUT" "missing    ~/.local/share/dotfiles/monitor-volume/dotfiles-monitor-volume"
    assert_contains "$RUN_OUTPUT" "missing    Monitor volume service (~/.config/systemd/user/dotfiles-monitor-volume.service)"

    # Without PipeWire's tools, the step changes nothing
    (
        hide pw-metadata
        assert_exit 1 main
        assert_file_not_contains "$STUB_LOG" "sudo"
        [ ! -e "$script" ] || fail "the script was installed without pw-metadata"
    )

    # A declined confirm installs the service, whose keys fall back to software volume
    answer no
    assert_exit 0 main
    assert_file_not_contains "$STUB_LOG" "apt-get"
    [ -x "$script" ] || fail "the script wasn't installed"

    answer yes
    assert_exit 0 main
    assert_file_contains "$STUB_LOG" "install -y ddcutil"
    assert_file_contains "$unit" "ExecStart=\"$script\" watch"
    assert_file_contains "$unit" "ExecStopPost=\"$script\" release"
    [ -e "$STATE/user-dotfiles-monitor-volume.service.active" ] || fail "the service isn't running"
    assert_idempotent main
    assert_contains "$RUN_OUTPUT" "ddcutil is already installed."
    assert_contains "$RUN_OUTPUT" "The monitor volume service is already running."

    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         Monitor volume service running"
    assert_contains "$RUN_OUTPUT" "ok         The monitor answers volume over DDC/CI"
    touch "$SANDBOX/ddc-fails"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "unverified The monitor answers volume over DDC/CI"
    rm "$SANDBOX/ddc-fails"

    # A changed script restarts the service, which runs from it
    echo "# old" >> "$script"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Restarted the monitor volume service."
    assert_exit 0 main
    assert_not_contains "$RUN_OUTPUT" "Restarted"

    # With no GNOME desktop, as on Ubuntu Server, it skips
    (
        hide gnome-shell
        assert_exit 0 main
        assert_contains "$RUN_OUTPUT" "No GNOME desktop, so skipped."
    )
}
subtest the_step
test_done
