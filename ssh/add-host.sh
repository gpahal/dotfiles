#!/bin/bash
set -euo pipefail

# Add a keepalive and connection-sharing block for a host to ~/.ssh/config. Setup doesn't run it.
# Usage: bash ssh/add-host.sh <alias> [hostname], e.g. bash ssh/add-host.sh desktop garvits-desktop.
# The hostname defaults to the alias; without MagicDNS, give the full <machine>.<tailnet>.ts.net name.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/hosts.sh
source "$DOTFILES_DIR/ssh/lib/hosts.sh"

check_name() {
    case "$2" in
        *[[:space:]*?!,#\"\'\\]*)
            echo "The $1 can't contain whitespace, *, ?, !, a comma, #, a quote, or a backslash: $2" >&2
            return 2
            ;;
    esac
}

main() {
    local alias="${1:-}" hostname="${2:-${1:-}}" block
    if [ -z "$alias" ] || [[ "$alias" == -* ]]; then
        echo "Usage: bash ssh/add-host.sh <alias> [hostname]" >&2
        return 1
    fi
    check_name alias "$alias" || return
    check_name hostname "$hostname" || return
    if host_line "$alias"; then
        echo "$SSH_CONFIG already has a block for $alias; leaving it alone."
        return 0
    fi
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    # Short ControlPersist: anything running as you can reuse the open connection without auth
    block="Host $alias
  HostName $hostname
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 1m"
    add_block "$block" || return 1
    chmod 600 "$SSH_CONFIG"
    echo "Added a block for $alias ($hostname) to $SSH_CONFIG. Connect with: ssh $alias"
    echo "It reuses one connection until a minute after the last session closes; ssh -O exit $alias closes it."
}

main "$@"
