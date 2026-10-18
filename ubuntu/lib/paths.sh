# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this file read them
# The system paths ubuntu/install.sh, ubuntu/setup-alerts.sh, and ubuntu/health-alert.sh share.
# Unlike the other files here, it only sets constants. The root hooks, ubuntu/smartd-notify.sh and
# ubuntu/ups-notify.sh, keep their own copies of NTFY_URL_FILE, since they run away from the repo.

# smartd's warning hook. smartd-runner runs each file in run.d on a warning, and run-parts
# --lsbsysinit skips a name with a dot.
SMARTD_HOOK=/etc/smartmontools/run.d/50dotfiles-notify
# upsmon's NOTIFYCMD, which pushes the UPS's events to ntfy
UPS_NOTIFY=/usr/local/libexec/dotfiles-ups-notify
# The ntfy topic URL the smartd and UPS hooks and the health alerts push to, which
# bash ubuntu/setup-alerts.sh saves
NTFY_URL_FILE=/etc/dotfiles/ntfy-url
