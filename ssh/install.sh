#!/bin/bash
set -euo pipefail

# macOS: add a Host * block to ~/.ssh/config that loads keys into the agent from the keychain, and
# a LaunchAgent that does so at login. Ubuntu has no keychain, so it gets neither. Other tools
# (e.g. OrbStack) add their own lines to that file, so it's never replaced, and a Host * block you
# wrote is never edited.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/hosts.sh
source "$DOTFILES_DIR/ssh/lib/hosts.sh"

SSH_CONFIG="$HOME/.ssh/config"
SSH_ADD_LABEL="dotfiles.ssh-add"
SSH_ADD_AGENT="$HOME/Library/LaunchAgents/$SSH_ADD_LABEL.plist"

# Keep a blank line between existing content and a block appended next
start_block() {
    if [ -s "$SSH_CONFIG" ]; then
        end_with_newline "$SSH_CONFIG" && echo "" >> "$SSH_CONFIG"
    fi
}

# Print, a line each, the settings that apply to every host, and a marker for each of these:
# ignoreunknown-usekeychain when ssh skips UseKeychain lines, and ignoreunknown-top when it
# doesn't, and an IgnoreUnknown at the top of the first Host * block wouldn't make it. Lines above
# the first Host or Match line apply to every host too, so they count as Host *'s. A block that
# lists other patterns too, such as Host * !bastion, leaves some host out. Only Apple's ssh knows
# UseKeychain, and any other, such as Homebrew's openssh, stops at it, in any block, unless the
# IgnoreUnknown in effect names it. That's the first IgnoreUnknown ssh reads, so it must name
# UseKeychain and come before every UseKeychain line.
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
        # ssh ignores a commented-out setting, such as #UseKeychain yes
        star && keyword !~ /^(#|$)/ { print keyword }
        # An IgnoreUnknown above every Host line comes before the block, as does a UseKeychain line
        # above its Host line
        END {
            if (!named && (ignore_global || (keychain_line && (!star_line || keychain_line < star_line))))
                print "ignoreunknown-top"
        }
    ' "$SSH_CONFIG"
}

# Print the lines to add to the Host * block, as they'd be written and in the order ssh needs:
# "IgnoreUnknown UseKeychain", "AddKeysToAgent yes", and "UseKeychain yes", each unless a block
# for * alone already sets it, as host_star_settings reads the config
host_star_missing() {
    local found
    found="$(host_star_settings)"
    grep -qx ignoreunknown-usekeychain <<< "$found" || echo "  IgnoreUnknown UseKeychain"
    grep -qx addkeystoagent <<< "$found" || echo "  AddKeysToAgent yes"
    grep -qx usekeychain <<< "$found" || echo "  UseKeychain yes"
}

# Succeeds when the IgnoreUnknown line must go at the top of the config, above the first
# UseKeychain line or IgnoreUnknown ssh reads, rather than at the top of the Host * block
ignore_unknown_at_top() {
    host_star_settings | grep -qx ignoreunknown-top
}

# macOS: a Host * block at the end, so every host loads its key into the agent and the agent
# takes the passphrase from the keychain. ssh uses the first value it finds for each setting, so
# the blocks above it still win. No IdentityFile: that would replace ssh's default identities.
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

# Print the Host * item. The step leaves your own Host * block alone, so the item names the lines
# to add to it by hand, and where.
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

# Succeeds when HOME is your account's home directory. launchctl loads into your real login
# session whatever HOME is, so a test with a temp HOME mustn't load its copy of the agent.
home_is_real() {
    [ "$HOME" == "$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')" ]
}

ssh_add_agent_loaded() {
    launchctl print "gui/$(id -u)/$SSH_ADD_LABEL" &>/dev/null
}

# Pass each file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it. Only macOS gets the LaunchAgent.
ssh_files() {
    is_macos || return 0
    "$1" "$DOTFILES_DIR/ssh/$SSH_ADD_LABEL.plist" "$SSH_ADD_AGENT"
}

# macOS: a LaunchAgent that runs ssh-add --apple-load-keychain at login, so the agent holds the
# key before any ssh command has loaded it. git signs commits through the agent, and agents
# such as T3 Code's have no terminal to type the passphrase into.
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

# Succeeds when only you can read ~/.ssh, as main sets it
ssh_dir_private() {
    [ -d "$HOME/.ssh" ] && [ "$(file_mode "$HOME/.ssh/")" == 700 ]
}

status() {
    status_check "Only you can read ~/.ssh (mode 700)" ssh_dir_private
    if is_macos; then
        status_host_star
        ssh_files status_file
        status_check "The $SSH_ADD_LABEL LaunchAgent is loaded, so login loads your keys from the keychain" \
            ssh_add_agent_loaded
    else
        status_item skipped "A Host * block that loads keys from the keychain: macOS only, Ubuntu has no keychain"
        status_item skipped "The $SSH_ADD_LABEL LaunchAgent: macOS only, Ubuntu has no keychain"
    fi
    status_result
}

apply() {
    echo "Configuring SSH..."
    local status=0
    mkdir -p "$HOME/.ssh" || return 1
    chmod 700 "$HOME/.ssh" || status=1
    if is_macos; then
        add_host_star || status=1
        install_ssh_add_agent || status=1
    else
        echo "  Skipping the keychain's Host * block and the LaunchAgent: macOS only"
    fi
    [ ! -f "$SSH_CONFIG" ] || chmod 600 "$SSH_CONFIG" || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
