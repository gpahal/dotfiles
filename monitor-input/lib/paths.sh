# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this file read them
# dotfiles-monitor-input keeps its own copy of the Ubuntu paths, since it runs away from the repo.

MONITOR_INPUT_MAC_CONF="$HOME/.hammerspoon/monitor-input.conf"
MONITOR_INPUT_CONF=/etc/dotfiles/monitor-input.conf
MONITOR_INPUT_RULE=/etc/udev/rules.d/90-dotfiles-monitor-input.rules
MONITOR_INPUT_SCRIPT=/usr/local/libexec/dotfiles-monitor-input
MONITOR_INPUT_UNIT=/etc/systemd/system/dotfiles-monitor-input.service
USB_DEVICES_DIR=/sys/bus/usb/devices
DRM_DIR=/sys/class/drm
