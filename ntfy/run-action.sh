#!/bin/bash
set -u

# Usage: run-action.sh <action>
# Shows the command an ntfy message's action runs, here or over ssh, and runs it once you press
# Enter. notify.sh opens it in a new Ghostty tab when you click the notification. The ntfy step
# copies it to ~/.local/share/dotfiles/ntfy, so it mustn't depend on the repo.

# shellcheck source=actions.sh
source "$(dirname "${BASH_SOURCE[0]}")/actions.sh" || exit 127

action="${1:-}"
if ! action_resolve "$action"; then
    echo "$action isn't an action this computer can run; ntfy/actions.sh lists them." >&2
    exit 1
fi
if [ -n "$ACTION_HOST" ]; then
    where="$ACTION_HOST"
    command="ssh -t $ACTION_HOST $(sh_quote "$ACTION_COMMAND")"
else
    where="this computer"
    command="$ACTION_COMMAND"
fi
printf '%s, on %s:\n\n  %s\n\n' "$ACTION_LABEL" "$where" "$command"
if ! read -r -p "Press Enter to run it, or Ctrl-C to cancel. " _; then
    echo
    exit 1
fi
exec "${SHELL:-/bin/bash}" -c "$command"
