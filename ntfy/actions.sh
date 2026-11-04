# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034 # the target's shell expands the commands; the callers read the rest
# The actions an ntfy message can name, and where each runs. Sourced by notify.sh and
# run-action.sh, which the ntfy step copies beside it to ~/.local/share/dotfiles/ntfy, so it mustn't
# depend on the repo.
#
# A message names one with the tag action:<name>. A bare name runs on the computer that shows the
# notification; linux-<name> runs on the Ubuntu desktop, and mac-<name> on the Mac, over ssh from
# the other one. Only the names action_spec lists run, with no arguments, so a message can't choose
# what runs. The Mac reaches the desktop by the ntfy server's name in its client config; Ubuntu
# knows no Mac, so it doesn't offer mac- actions.

ACTION_CHECKOUT_CMD='cd "$(cat ~/.local/state/dotfiles/checkout)"'

# action_spec <name>: sets ACTION_OSES, the OSes it runs on, ACTION_LABEL, and ACTION_COMMAND, as
# the target computer's shell runs it. Each shows what's wrong, where, and how to fix it.
action_spec() {
    case "$1" in
        status)
            ACTION_OSES="macos ubuntu"
            ACTION_LABEL="Show status"
            ACTION_COMMAND="$ACTION_CHECKOUT_CMD && sudo -v && just status"
            ;;
        disk)
            ACTION_OSES=ubuntu
            ACTION_LABEL="Show disk health"
            ACTION_COMMAND='journalctl -t smartd -n 30 --no-pager; for disk in $(sudo smartctl --scan | cut -d " " -f 1); do sudo smartctl -H -A "$disk"; done'
            ;;
        ups)
            ACTION_OSES=ubuntu
            ACTION_LABEL="Show UPS"
            ACTION_COMMAND='upsc ups@localhost; journalctl -t upsmon -n 30 --no-pager'
            ;;
        health-log)
            ACTION_OSES=ubuntu
            ACTION_LABEL="Show health check log"
            ACTION_COMMAND='journalctl --user -u dotfiles-health -n 50 --no-pager'
            ;;
        *) return 1 ;;
    esac
}

action_this_os() {
    if [ "$(uname -s)" == Darwin ]; then
        echo macos
    else
        echo ubuntu
    fi
}

# The ntfy server's host, from the client config's default-host: the desktop, as the Mac sees it
action_desktop_host() {
    local config="$HOME/Library/Application Support/ntfy/client.yml" host
    host="$(sed -nE 's|^default-host: *https?://([A-Za-z0-9.-]+)(:[0-9]+)?/? *$|\1|p' "$config" 2> /dev/null |
        head -n 1)"
    [ -n "$host" ] || return 1
    printf '%s\n' "$host"
}

# action_resolve <action>: fails unless it's an action this computer can run. Sets ACTION_LABEL,
# ACTION_COMMAND, and ACTION_HOST, the host to ssh to, or empty to run it here.
action_resolve() {
    local action="$1" name os here
    case "$action" in
        '' | -* | *[!a-z0-9-]* | *- | *--*) return 1 ;;
    esac
    here="$(action_this_os)"
    case "$action" in
        linux-*) name="${action#linux-}" os=ubuntu ;;
        mac-*) name="${action#mac-}" os=macos ;;
        *) name="$action" os="$here" ;;
    esac
    action_spec "$name" || return 1
    case " $ACTION_OSES " in *" $os "*) ;; *) return 1 ;; esac
    ACTION_HOST=""
    if [ "$os" != "$here" ]; then
        [ "$os" == ubuntu ] || return 1
        ACTION_HOST="$(action_desktop_host)" || return 1
    fi
}

# action_from_tags <comma-separated tags>: the first action:<name> tag's name
action_from_tags() {
    local tag rest="$1,"
    while [ -n "$rest" ]; do
        tag="${rest%%,*}"
        rest="${rest#*,}"
        case "$tag" in action:?*)
            printf '%s\n' "${tag#action:}"
            return 0
            ;;
        esac
    done
    return 1
}

# sh_quote <string>: single-quoted for sh, bash, and zsh
sh_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
