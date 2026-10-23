# Touch ID sudo_local config and its status check, shared by the macos step and just touch-id.
# The DOTFILES_PAM_* variables are for tests.
# shellcheck shell=bash

PAM_DIR="${DOTFILES_PAM_DIR:-/etc/pam.d}"
# OpenPAM's search order for a bare module name
PAM_MODULES_DIR="${DOTFILES_PAM_MODULES_DIR:-/usr/lib/pam}"
PAM_LOCAL_MODULES_DIR="${DOTFILES_PAM_LOCAL_MODULES_DIR:-/usr/local/lib/pam}"
SUDO_LOCAL="$PAM_DIR/sudo_local"
# Matches macOS's sudo_local.template
SUDO_LOCAL_HEADER="# sudo_local: local config file which survives system update and is included for sudo"
TID_LINE="auth       sufficient     pam_tid.so"

# A root-owned copy: sudo loads it as root, and anything running as you can write Homebrew's.
REATTACH_MODULE="$PAM_LOCAL_MODULES_DIR/pam_reattach.so"
# Tests override it
PAM_ROOT_UID=0

REATTACH_SOURCE="${HOMEBREW_PREFIX:-/opt/homebrew}/lib/pam/pam_reattach.so"

reattach_source_installed() {
    [ -f "$REATTACH_SOURCE" ]
}

pam_owner_safe() {
    local perms owner
    read -r perms _ owner _ < <(/bin/ls -ldn "$1" 2>/dev/null) || return 1
    [ "$owner" == "$PAM_ROOT_UID" ] && [ "${perms:5:1}" != w ] && [ "${perms:8:1}" != w ]
}

# Prints why non-root can change <path>, with the fix, or nothing. ls -e prints ACL entries on
# numbered lines, such as " 0: group:everyone allow add_file,delete_child".
pam_entry_unsafe() {
    local path="$1" listing perms owner
    if [ -L "$path" ]; then
        echo "$path is a symlink; remove it with sudo rm $path"
        return 0
    fi
    [ -e "$path" ] || return 0
    if ! listing="$(/bin/ls -ldne "$path" 2>/dev/null)"; then
        echo "couldn't read $path's owner; check it with ls -lde $path"
        return 0
    fi
    read -r perms _ owner _ <<< "${listing%%$'\n'*}"
    if [ "$owner" != "$PAM_ROOT_UID" ] || [ "${perms:5:1}" == w ] || [ "${perms:8:1}" == w ]; then
        echo "$path isn't root's alone to write; run sudo chown root $path && sudo chmod go-w $path"
    elif printf '%s\n' "$listing" | awk '
        NR > 1 && $1 ~ /^[0-9]+:$/ {
            for (i = 2; i < NF; i++) {
                if ($i != "allow") continue
                n = split($(i + 1), perms, ",")
                for (j = 1; j <= n; j++)
                    if (perms[j] ~ /^(write|append|add_file|add_subdirectory|delete|delete_child|writeattr|writeextattr|writesecurity|chown)$/)
                        found = 1
            }
        }
        END { exit !found }'; then
        echo "$path has an ACL entry that lets others write it; remove it with sudo chmod -N $path"
    fi
}

# Prints a problem with where sudo reads sudo_local that just touch-id can't fix, and succeeds;
# fails when there's none. A link is refused, since writing it would write its target.
sudo_local_blocker() {
    local reason
    reason="$(pam_entry_unsafe "$PAM_DIR")"
    if [ -z "$reason" ] && [ -L "$SUDO_LOCAL" ]; then
        reason="$(pam_entry_unsafe "$SUDO_LOCAL")"
    fi
    [ -n "$reason" ] && echo "$reason"
}

# Prints why non-root can change sudo_local, or nothing. just touch-id's rewrite fixes it, since it
# installs a fresh root-owned file.
sudo_local_unsafe() {
    [ -L "$SUDO_LOCAL" ] || pam_entry_unsafe "$SUDO_LOCAL"
}

reattach_in_use() {
    [ -f "$REATTACH_MODULE" ] || reattach_source_installed
}

# Problems reinstalling the copy fixes
reattach_module_replaceable() {
    [ -L "$REATTACH_MODULE" ] || { [ -e "$REATTACH_MODULE" ] && ! pam_owner_safe "$REATTACH_MODULE"; }
}

# Prints a problem just touch-id can't fix, and succeeds; fails when there's none. Checks the copy
# and its folder, not the folders above them.
reattach_blocker() {
    local reason
    reattach_in_use || return 1
    # OpenPAM tries the name with its major version first
    if [ -e "$REATTACH_MODULE.2" ] || [ -L "$REATTACH_MODULE.2" ]; then
        echo "$REATTACH_MODULE.2 exists, and OpenPAM loads it instead of the copy; remove it with sudo rm $REATTACH_MODULE.2, then re-run just touch-id"
    elif reason="$(pam_entry_unsafe "$PAM_LOCAL_MODULES_DIR")" && [ -n "$reason" ]; then
        echo "sudo can't safely load $REATTACH_MODULE: $reason, then re-run just touch-id"
    elif reattach_module_replaceable; then
        reattach_source_installed && return 1
        reason="isn't root's alone to write"
        [ ! -L "$REATTACH_MODULE" ] || reason="is a symlink"
        echo "$REATTACH_MODULE, which sudo loads, $reason; run brew install pam-reattach, then just touch-id"
    else
        # Only the copy's ACL is left to check
        reason="$(pam_entry_unsafe "$REATTACH_MODULE")"
        [ -n "$reason" ] || return 1
        echo "sudo can't safely load $REATTACH_MODULE: $reason, then re-run just touch-id"
    fi
}

reattach_copy_needed() {
    reattach_source_installed || return 1
    [ ! -f "$REATTACH_MODULE" ] || reattach_module_replaceable || ! cmp -s "$REATTACH_SOURCE" "$REATTACH_MODULE"
}

# pam_reattach must precede pam_tid for tmux. ignore_ssh: over SSH, ask for the password instead.
repo_sudo_local_lines() {
    if [ -f "$REATTACH_MODULE" ] || reattach_source_installed; then
        echo "auth       optional       $REATTACH_MODULE ignore_ssh"
    fi
    echo "$TID_LINE"
}

# The repo owns sudo_local, so it holds only these lines
desired_sudo_local() {
    echo "$SUDO_LOCAL_HEADER"
    repo_sudo_local_lines
}

has_tid() {
    [ -f "$SUDO_LOCAL" ] && awk '$1 == "auth" && $3 ~ /(^|\/)pam_tid\.so$/ { found = 1 } END { exit !found }' "$SUDO_LOCAL"
}

pam_module_path() {
    local dir
    if [[ "$1" == /* ]]; then
        echo "$1"
        return
    fi
    for dir in "$PAM_MODULES_DIR" "$PAM_LOCAL_MODULES_DIR"; do
        if pam_module_exists "$dir/$1"; then
            echo "$dir/$1"
            return
        fi
    done
    echo "$PAM_MODULES_DIR/$1"
}

sudo_local_modules() {
    local module
    [ -f "$SUDO_LOCAL" ] || return 0
    awk '$1 !~ /^#/ && NF >= 3 && $2 != "include" { print $3 }' "$SUDO_LOCAL" |
        while IFS= read -r module; do
            pam_module_path "$module"
        done
}

# OpenPAM also tries <name>.2, which is how macOS ships its modules
pam_module_exists() {
    [ -f "$1" ] || [ -f "$1.2" ]
}

# For when a missing module breaks sudo itself
sudo_local_rescue() {
    echo "osascript -e 'do shell script \"rm $SUDO_LOCAL\" with administrator privileges'"
}

# status_touch_id <state for off: missing|skipped>
status_touch_id() {
    local off="$1" module blocker unsafe rescue
    if [ -e "$SUDO_LOCAL" ] && [ ! -r "$SUDO_LOCAL" ]; then
        status_item unverified "Touch ID for sudo: $SUDO_LOCAL isn't readable; check it with sudo cat $SUDO_LOCAL"
        return 0
    fi
    if blocker="$(sudo_local_blocker)"; then
        status_item missing "Touch ID for sudo: $blocker"
    fi
    unsafe="$(sudo_local_unsafe)"
    if ! has_tid; then
        status_item "$off" "Touch ID for sudo: off, an option that just touch-id turns on"
    elif [ "$(cat "$SUDO_LOCAL")" == "$(desired_sudo_local)" ]; then
        if [ -n "$unsafe" ]; then
            status_item missing "Touch ID for sudo: $unsafe, or re-run just touch-id, which rewrites it"
        else
            status_item ok "Touch ID for sudo, in $SUDO_LOCAL"
        fi
        if blocker="$(reattach_blocker)"; then
            status_item missing "Touch ID in tmux: $blocker"
        elif ! reattach_in_use; then
            status_item skipped "Touch ID in tmux: pam-reattach isn't installed; the homebrew step installs it, then re-run just touch-id"
        # A missing copy is reported by the module loop below
        elif { [ -e "$REATTACH_MODULE" ] || [ -L "$REATTACH_MODULE" ]; } && reattach_copy_needed; then
            if reattach_module_replaceable; then
                status_item missing "Touch ID in tmux: $REATTACH_MODULE, which sudo loads, isn't a root-owned copy of Homebrew's pam-reattach module; re-run just touch-id"
            else
                status_item missing "Touch ID in tmux: $REATTACH_MODULE, which sudo loads, is older than Homebrew's pam-reattach; re-run just touch-id"
            fi
        fi
    else
        status_item missing "Touch ID for sudo: $SUDO_LOCAL differs from what just touch-id writes; run it to replace the file"
    fi
    # A missing module can break sudo, so give a fix that doesn't need it
    rescue="If sudo fails, remove the file without it: $(sudo_local_rescue)"
    while IFS= read -r module; do
        pam_module_exists "$module" && continue
        if [[ "$module" == */pam_reattach.so ]]; then
            status_item missing "$SUDO_LOCAL loads $module, which doesn't exist, so Touch ID in tmux doesn't work and sudo may fail; run brew install pam-reattach, then just touch-id. $rescue"
        else
            status_item missing "$SUDO_LOCAL loads $module, which doesn't exist, so sudo may fail; remove that line from it, or install the module. $rescue"
        fi
    done < <(sudo_local_modules)
}
