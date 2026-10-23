#!/bin/bash
set -euo pipefail

# Make ~/.ssh private, and on macOS keep SSH keys in the keychain, loaded at login.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/hosts.sh
source "$DOTFILES_DIR/ssh/lib/hosts.sh"

SSH_ADD_LABEL="dotfiles.ssh-add"
SSH_ADD_AGENT="$HOME/Library/LaunchAgents/$SSH_ADD_LABEL.plist"

start_block() {
    if [ -s "$SSH_CONFIG" ]; then
        end_with_newline "$SSH_CONFIG" && echo "" >> "$SSH_CONFIG"
    fi
}

# Prints each setting that applies to every host, plus ignoreunknown-usekeychain or
# ignoreunknown-top. Non-Apple ssh fails on UseKeychain unless the first IgnoreUnknown it reads,
# before every UseKeychain line, names it.
host_star_settings() {
    [ -f "$SSH_CONFIG" ] || return 0
    awk "$SSH_CONFIG_AWK"'
        BEGIN { star = 1; global = 1 }
        { keyword = ssh_keyword($0) }
        keyword == "host" || keyword == "match" {
            star = keyword == "host" && host_patterns($0, p) == 1 && p[1] == "*"
            global = 0
            if (star && !star_line) star_line = NR
            next
        }
        keyword == "ignoreunknown" && star && !ignore_seen {
            ignore_seen = 1
            ignore_global = global
            args = tolower($0)
            sub(/#.*/, "", args)
            sub(/^[ \t]*[^ \t=]*[ \t]*=?[ \t]*/, "", args)
            n = split(args, names, /[ \t,]+/)
            for (i = 1; i <= n; i++) if (names[i] == "usekeychain" && !keychain_line) named = 1
            if (named) print "ignoreunknown-usekeychain"
        }
        keyword == "usekeychain" && !keychain_line { keychain_line = NR }
        star && keyword !~ /^(#|$)/ { print keyword }
        END {
            if (!named && (ignore_global || (keychain_line && (!star_line || keychain_line < star_line))))
                print "ignoreunknown-top"
        }
    ' "$SSH_CONFIG"
}

# In the order ssh needs
host_star_missing() {
    local found
    found="$(host_star_settings)"
    grep -qx ignoreunknown-usekeychain <<< "$found" || echo "  IgnoreUnknown UseKeychain"
    grep -qx addkeystoagent <<< "$found" || echo "  AddKeysToAgent yes"
    grep -qx usekeychain <<< "$found" || echo "  UseKeychain yes"
}

ignore_unknown_at_top() {
    host_star_settings | grep -qx ignoreunknown-top
}

# Appended, so earlier blocks win. No IdentityFile: it would replace ssh's default identities.
add_host_star() {
    local missing top=""
    missing="$(host_star_missing)"
    if [ -z "$missing" ]; then
        echo "  $SSH_CONFIG already loads keys into the agent from the keychain for every host"
        return 0
    fi
    if ignore_unknown_at_top; then
        top=true
        missing="$(grep -v IgnoreUnknown <<< "$missing" || true)"
    fi
    if ! host_star_block; then
        start_block &&
            printf 'Host *\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n' >> "$SSH_CONFIG" ||
            return 1
        echo "  Added a Host * block that loads keys into the agent from the keychain to $SSH_CONFIG"
    elif [ -n "$missing" ]; then
        echo "  $SSH_CONFIG already has a Host * block, so it's left alone. To have ssh load"
        echo "  keys into the agent from the keychain, add these lines to the top of it:"
        printf '%s\n' "$missing" | sed 's/^/  /'
    fi
    if [ -n "$top" ]; then
        echo "  ssh reads only the first IgnoreUnknown, which must come before every UseKeychain"
        echo "  line, so add this line at the top of $SSH_CONFIG:"
        echo "    IgnoreUnknown UseKeychain"
    fi
}

status_host_star() {
    local text="The Host * block in ~/.ssh/config has IgnoreUnknown UseKeychain, AddKeysToAgent, and UseKeychain" missing
    local top="" fix
    missing="$(host_star_missing)"
    if [ -z "$missing" ]; then
        status_item ok "$text"
    elif host_star_block; then
        if ignore_unknown_at_top; then
            top="IgnoreUnknown UseKeychain at the top of the file"
            missing="$(grep -v IgnoreUnknown <<< "$missing" || true)"
        fi
        fix="$(awk '{ sub(/^ +/, "") } NR > 1 { printf " and " } { printf "%s", $0 }' <<< "$missing")"
        [ -z "$fix" ] || fix="$fix to the top of it"
        if [ -n "$top" ]; then
            fix="${fix:+$fix and }$top"
        fi
        status_item missing "$text; add $fix by hand"
    else
        status_item missing "$text"
    fi
}

# launchctl loads into the real session whatever HOME is, so a temp HOME mustn't load it
home_is_real() {
    [ "$HOME" == "$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')" ]
}

ssh_add_agent_loaded() {
    launchctl print "gui/$(id -u)/$SSH_ADD_LABEL" &>/dev/null
}

ssh_files() {
    is_macos || return 0
    "$1" "$DOTFILES_DIR/ssh/$SSH_ADD_LABEL.plist" "$SSH_ADD_AGENT"
}

# git signs through the agent, and agents such as T3 Code's can't type a passphrase
install_ssh_add_agent() {
    ssh_files copy_file || return 1
    if ssh_add_agent_loaded; then
        echo "  The $SSH_ADD_LABEL LaunchAgent is already loaded. A changed copy takes effect at the next login."
    elif ! home_is_real; then
        echo "  HOME isn't your home directory, so the $SSH_ADD_LABEL LaunchAgent isn't loaded. Load it with:"
        echo "    launchctl bootstrap gui/$(id -u) $SSH_ADD_AGENT"
    elif launchctl bootstrap "gui/$(id -u)" "$SSH_ADD_AGENT"; then
        echo "  Loaded the $SSH_ADD_LABEL LaunchAgent, which loads your keys from the keychain at login"
    else
        echo "  Couldn't load the $SSH_ADD_LABEL LaunchAgent." >&2
        return 1
    fi
}

ssh_dir_private() {
    [ -d "$HOME/.ssh" ] && [ "$(file_mode "$HOME/.ssh/")" == 700 ]
}

make_ssh_dir_private() {
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && echo "  Set ~/.ssh to mode 700"
}

ssh_config_private() {
    [ ! -f "$SSH_CONFIG" ] || [ "$(file_mode "$SSH_CONFIG")" == 600 ]
}

make_ssh_config_private() {
    chmod 600 "$SSH_CONFIG" && echo "  Set ~/.ssh/config to mode 600"
}

ssh_items() {
    items_reset
    item "Only you can read ~/.ssh (mode 700)" "Set ~/.ssh to mode 700" ssh_dir_private make_ssh_dir_private
    item "Only you can read ~/.ssh/config (mode 600)" "Set ~/.ssh/config to mode 600" \
        ssh_config_private make_ssh_config_private
}

status() {
    ssh_items
    items_status
    if is_macos; then
        status_host_star
        ssh_files status_file
        status_check "The $SSH_ADD_LABEL LaunchAgent is loaded, so login loads your keys from the keychain" \
            ssh_add_agent_loaded
    else
        status_item skipped "A Host * block that loads keys from the keychain: macOS only, Ubuntu has no keychain"
        status_item skipped "The $SSH_ADD_LABEL LaunchAgent: macOS only, Ubuntu has no keychain"
    fi
}

apply() {
    echo "Configuring SSH..."
    local status=0 private=false
    ssh_items
    ! { ssh_dir_private && ssh_config_private; } || private=true
    items_apply ssh_dir_private || status=1
    [ -d "$HOME/.ssh" ] || return 1
    if is_macos; then
        add_host_star || status=1
        install_ssh_add_agent || status=1
    else
        echo "  Skipping the keychain's Host * block and the LaunchAgent: macOS only"
    fi
    # add_host_star may create the file
    items_apply ssh_config_private || status=1
    ! "$private" || echo "  ~/.ssh and its config are already private"
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
