# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this file read them
# The root hooks hard-code NTFY_URL_FILE too, since they run outside the repo.

# The checkout health-alert.sh runs status in
DOTFILES_REPO="${DOTFILES_REPO:-$HOME/Dev/setup/dotfiles}"

# No dot in the name: run-parts --lsbsysinit skips it
SMARTD_HOOK=/etc/smartmontools/run.d/50dotfiles-notify
UPS_NOTIFY=/usr/local/libexec/dotfiles-ups-notify
NTFY_URL_FILE=/etc/dotfiles/ntfy-url
