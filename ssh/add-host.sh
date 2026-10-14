#!/bin/bash
set -euo pipefail

# Add a block for a host you SSH to, such as the Ubuntu machine, to ~/.ssh/config: keepalives, so
# idle sessions don't drop, and one shared connection per host, so T3 Code, Zed, and new terminals
# connect without a new handshake. The block goes above the first Host * or Match all, since ssh
# uses the first value it finds for each setting. The host is yours to name, so setup doesn't run
# this.
# Usage: bash ssh/add-host.sh <alias> [hostname], e.g. bash ssh/add-host.sh box box.tail1234.ts.net

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/hosts.sh
source "$DOTFILES_DIR/ssh/lib/hosts.sh"

SSH_CONFIG="$HOME/.ssh/config"

# Fail when ssh would read the value as more than one pattern, a pattern, or a comment
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
    block="Host $alias
  HostName $hostname
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m"
    add_block "$block" || return 1
    chmod 600 "$SSH_CONFIG"
    echo "Added a block for $alias ($hostname) to $SSH_CONFIG. Connect with: ssh $alias"
    echo "It reuses one connection until 10 minutes after the last session closes; ssh -O exit $alias closes it."
}

main "$@"
