#!/bin/bash
set -u

# Run ntfy subscribe for the client config's topics, from just before the newest message notify.sh
# showed, so messages sent while it wasn't connected still show.
# The ntfy step copies it to ~/.local/share/dotfiles/ntfy, where the notifier's user unit or
# LaunchAgent runs it, so it mustn't depend on the repo. ntfy keeps messages for its cache-duration,
# and replays everything after --since on each reconnect; notify.sh drops the repeats.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ntfy"
# Where ntfy's client reads it, Go's os.UserConfigDir
if [ "$(uname -s)" == Darwin ]; then
    CONFIG="$HOME/Library/Application Support/ntfy/client.yml"
else
    CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/ntfy/client.yml"
fi
# Without state yet, only the last few minutes, not the whole cache
FIRST_SINCE=10m

# Waits rather than exits, so the service manager doesn't restart it in a loop until just ntfy-user
# or just ntfy-device writes the config
while [ ! -r "$CONFIG" ]; do
    sleep 60
done

last="$(head -n 1 "$STATE_DIR/last-time" 2>/dev/null)" || last=""
case "$last" in
    '' | *[!0-9]*) since="$FIRST_SINCE" ;;
    # A second early, so a message from the same second isn't skipped
    *) since=$((last - 1)) ;;
esac
exec ntfy subscribe --config "$CONFIG" --from-config --since "$since"
