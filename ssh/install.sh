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

# Print the lines to add to the Host * block, as they'd be written: "AddKeysToAgent yes" and
# "UseKeychain yes", each unless a block for * alone already sets it. A block that lists other
# patterns too, such as Host * !bastion, leaves some host out. Lines above the first Host or Match
# line apply to every host too, so they count as Host *'s.
host_star_missing() {
    local found=""
    if [ -f "$SSH_CONFIG" ]; then
        found="$(awk "$SSH_CONFIG_AWK"'
            BEGIN { star = 1 }
            { keyword = ssh_keyword($0) }
            keyword == "host" || keyword == "match" {
                star = keyword == "host" && host_patterns($0, p) == 1 && p[1] == "*"
                next
            }
            # ssh ignores a commented-out setting, such as #UseKeychain yes
            star && keyword !~ /^(#|$)/ { print keyword }
        ' "$SSH_CONFIG")"
    fi
    case "$found" in *addkeystoagent*) ;; *) echo "  AddKeysToAgent yes" ;; esac
    case "$found" in *usekeychain*) ;; *) echo "  UseKeychain yes" ;; esac
}

# macOS: a Host * block at the end, so every host loads its key into the agent and the agent
# takes the passphrase from the keychain. ssh uses the first value it finds for each setting, so
# the blocks above it still win. No IdentityFile: that would replace ssh's default identities.
add_host_star() {
    local missing
    missing="$(host_star_missing)"
    if [ -z "$missing" ]; then
        echo "  $SSH_CONFIG already loads keys into the agent from the keychain for every host"
        return 0
    elif host_star_block; then
        echo "  $SSH_CONFIG already has a Host * block, so it's left alone. To have ssh load"
        echo "  keys into the agent from the keychain, add these lines to it:"
        printf '%s\n' "$missing" | sed 's/^/  /'
        return 0
    fi
    start_block && printf 'Host *\n  AddKeysToAgent yes\n  UseKeychain yes\n' >> "$SSH_CONFIG" || return 1
    echo "  Added a Host * block that loads keys into the agent from the keychain to $SSH_CONFIG"
}

# Print the Host * item. The step leaves your own Host * block alone, so the item names the lines
# to add to it by hand.
status_host_star() {
    local text="The Host * block in ~/.ssh/config has AddKeysToAgent and UseKeychain" missing
    if [ -z "$(host_star_missing)" ]; then
        status_item ok "$text"
    elif host_star_block; then
        missing="$(host_star_missing | sed 's/^ *//' | awk 'NR > 1 { printf " and " } { printf "%s", $0 }')"
        status_item missing "$text; add $missing to it by hand"
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

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Configuring SSH..."
    local status=0
    mkdir -p "$HOME/.ssh" || return 1
    chmod 700 "$HOME/.ssh" || status=1
    if is_macos; then
        add_host_star || status=1
        [ ! -f "$SSH_CONFIG" ] || chmod 600 "$SSH_CONFIG" || status=1
        install_ssh_add_agent || status=1
    else
        echo "  Skipping the keychain's Host * block and the LaunchAgent: macOS only"
        [ ! -f "$SSH_CONFIG" ] || chmod 600 "$SSH_CONFIG" || status=1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
