# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this file read them
# The root hooks hard-code NTFY_URL_FILE and NTFY_TOKEN_FILE too, since they run outside the repo.

# No dot in the name: run-parts --lsbsysinit skips it
SMARTD_HOOK=/etc/smartmontools/run.d/50dotfiles-notify
UPS_NOTIFY=/usr/local/libexec/dotfiles-ups-notify
NTFY_URL_FILE=/etc/dotfiles/ntfy-url
NTFY_TOKEN_FILE=/etc/dotfiles/ntfy-token

# The ntfy step's server listens on loopback only; Tailscale Funnel publishes it on this port
NTFY_LOCAL_URL=http://127.0.0.1:2586
NTFY_FUNNEL_PORT=8443
NTFY_ALERTS_URL="$NTFY_LOCAL_URL/alerts"
