# Helpers shared by the runners, steps, and scripts. Source it; don't run it.
# shellcheck shell=bash

# cd to a relative dir prints the match when CDPATH is exported
unset CDPATH
DOTFILES_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOTFILES_DIR
# Made absolute now, since a test that loads the step cd's to its sandbox after
case "${BASH_SOURCE[1]:-}" in
    /*) _SOURCED_BY="${BASH_SOURCE[1]}" ;;
    *) _SOURCED_BY="$PWD/${BASH_SOURCE[1]:-}" ;;
esac

# Worked out once, since status loops ask per cask. Tests switch it with as_os, or with a uname
# stub before this file loads.
case "$(uname -s)" in
    Darwin) _DOTFILES_OS=macos ;;
    Linux)
        _DOTFILES_OS=linux
        ! grep -qE '^ID="?ubuntu"?$' /etc/os-release 2>/dev/null || _DOTFILES_OS=ubuntu
        ;;
    *) _DOTFILES_OS=other ;;
esac

# Worked out once for the steps that name you. A test that stubs id -un sets it too.
# shellcheck disable=SC2034 # steps read it
CURRENT_USER="$(id -un)"

is_macos() {
    [ "$_DOTFILES_OS" == macos ]
}

is_ubuntu() {
    [ "$_DOTFILES_OS" == ubuntu ]
}

# app_config_dir <app>: the app's folder in XDG_CONFIG_HOME. On macOS, Zed, Ghostty and Vicinae read
# ~/.config whatever it is, since an app started from the Dock doesn't see a shell's.
app_config_dir() {
    if is_macos; then
        echo "$HOME/.config/$1"
    else
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/$1"
    fi
}

# Ubuntu Desktop, rather than Server, which has no apps to open
has_gnome_desktop() {
    command -v gnome-shell &>/dev/null
}

locale_installed() {
    locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'
}

# apt_installed <package>...: all are installed. Excludes packages removed with their config left.
apt_installed() {
    local package
    for package in "$@"; do
        [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" == *"install ok installed"* ]] || return 1
    done
}

# unattended-upgrades holds dpkg's lock for a while after boot
APT_LOCK_TIMEOUT=300

# LC_ALL=C keeps messages English for apt_lists_locked. The lock timeout doesn't cover apt-get
# update's lists lock; use apt_get_update for that.
apt_get() {
    sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"
}

APT_UPDATE_TRIES=20
APT_UPDATE_RETRY_DELAY=15

# Other errors also name the lock file but aren't worth a retry
apt_lists_locked() {
    grep -E '/var/lib/apt/lists/lock' | grep -qE 'Could not get lock|is held by|Unable to acquire'
}

# Retries while another update (e.g. apt-daily's) holds the lists lock. Notices go to stderr so
# callers that capture output, as add_apt_repo does, still show them.
# shellcheck disable=SC2120 # add_apt_repo, in lib/system.sh, passes arguments
apt_get_update() {
    local try=1 dir status
    dir="$(mktemp -d)" || return 1
    while :; do
        rm -f "$dir/status"
        { apt_get update "$@" 2>&1 || echo "$?" > "$dir/status"; } | tee "$dir/output"
        status="$(cat "$dir/status" 2>/dev/null || echo 0)"
        if [ "$status" -eq 0 ] || ! apt_lists_locked < "$dir/output" || [ "$try" -ge "$APT_UPDATE_TRIES" ]; then
            rm -rf "$dir"
            return "$status"
        fi
        echo "  apt's lists lock is held by another update; trying again in $APT_UPDATE_RETRY_DELAY s ($try of $APT_UPDATE_TRIES)." >&2
        sleep "$APT_UPDATE_RETRY_DELAY"
        try=$((try + 1))
    done
}

# Updates apt's lists first, since stale ones can name a version the mirror no longer has. One
# successful update serves the rest of the run, until add_apt_repo, in lib/system.sh, changes a
# source or key.
APT_LISTS_FRESH=""
apt_install_fresh() {
    if [ -z "$APT_LISTS_FRESH" ]; then
        apt_get_update || return 1
        APT_LISTS_FRESH=true
    fi
    apt_get install -y "$@"
}

# Compares as $(cat) would, without the fork: a missing file reads as empty, and trailing newlines
# don't count
file_is() {
    local content=""
    { IFS= read -r -d '' content < "$1"; } 2>/dev/null || true
    while [ "${content%$'\n'}" != "$content" ]; do
        content="${content%$'\n'}"
    done
    [ "$content" == "$2" ]
}

# left_unchanged <indent> <what to run> <what that does>: after a declined confirm, which says no
# without a terminal
left_unchanged() {
    if is_interactive; then
        echo "${1}Left unchanged."
    else
        echo "${1}Left unchanged. Run $2 from a terminal to $3."
    fi
}

confirm_sudo_changes() {
    echo "  These need sudo:"
    printf '    - %s\n' "$@"
    confirm "  Apply them?" && return 0
    left_unchanged "  " "this step" "apply them"
    return 1
}

require_supported_os() {
    if is_macos; then
        [ "$(uname -m)" != x86_64 ] && return 0
        echo "Intel Macs aren't supported: setup needs Apple Silicon, and this shell reports x86_64 (an Intel Mac, or Rosetta)." >&2
        return 1
    fi
    is_ubuntu && return 0
    echo "Only macOS and Ubuntu are supported." >&2
    return 1
}

# Homebrew's default prefixes, macOS's then Linux's. zsh/path.zsh, and zsh/profile.sh for Linux's,
# keep their own copies, since they run without this file.
HOMEBREW_PREFIXES=(/opt/homebrew /home/linuxbrew/.linuxbrew)

load_brew() {
    local prefix
    # Set by the tests to hide Homebrew
    [ -z "${DOTFILES_NO_LOAD_BREW:-}" ] || return 1
    for prefix in "${HOMEBREW_PREFIXES[@]}"; do
        if [ -x "$prefix/bin/brew" ]; then
            eval "$("$prefix/bin/brew" shellenv)"
            return 0
        fi
    done
    return 1
}

# Each step runs in its own process, so load Homebrew and mise's shims here
command -v brew &>/dev/null || load_brew || true
MISE_SHIMS="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
if [ -d "$MISE_SHIMS" ] && [[ ":$PATH:" != *":$MISE_SHIMS:"* ]]; then
    export PATH="$MISE_SHIMS:$PATH"
fi

export HOMEBREW_NO_ASK=1
export HOMEBREW_NO_ENV_HINTS=1

has_arg() {
    local flag="$1" arg
    shift
    for arg in "$@"; do
        [ "$arg" != "$flag" ] || return 0
    done
    return 1
}

status_requested() { has_arg --status "$@"; }

status_for_alerts() { [ "${DOTFILES_STATUS_FOR_ALERTS:-}" == 1 ]; }

# check_args <usage-fn> <words|no-words> [arg...]: exits 0 on --help and 2 on a bad argument.
# Other words go in ARG_WORDS. Flag effects are exported so a runner's steps inherit them.
check_args() {
    local usage_fn="$1" words="$2" arg
    shift 2
    ARG_WORDS=()
    for arg in "$@"; do
        case "$arg" in
            -h | --help)
                "$usage_fn"
                exit 0
                ;;
        esac
    done
    for arg in "$@"; do
        case "$arg" in
            --status) export HOMEBREW_NO_AUTO_UPDATE=1 ;;
            --for-alerts) export DOTFILES_STATUS_FOR_ALERTS=1 ;;
            --backup) export DOTFILES_BACKUP=yes ;;
            --no-backup) export DOTFILES_BACKUP=no ;;
            -*)
                echo "Unknown option: $arg" >&2
                "$usage_fn" >&2
                exit 2
                ;;
            *)
                if [ "$words" != words ]; then
                    echo "Unknown argument: $arg" >&2
                    "$usage_fn" >&2
                    exit 2
                fi
                ARG_WORDS+=("$arg")
                ;;
        esac
    done
    if ! status_requested "$@" && has_arg --for-alerts "$@"; then
        echo "--for-alerts only works with --status" >&2
        "$usage_fn" >&2
        exit 2
    fi
}

step_args() {
    local step_usage
    step_usage="Usage: bash $(_repo_path "$_SOURCED_BY") [--status [--for-alerts]] [--backup | --no-backup]"
    check_args _step_usage no-words "$@"
}

_step_usage() { echo "$step_usage"; }

# Prints the skip and succeeds when <os> isn't this OS; 1 when the step runs here, 2 when <os>
# is invalid
step_os_skip() {
    local step="$1" os="$2" label
    case "$os" in
        '') return 1 ;;
        macos)
            ! is_macos || return 1
            label="macOS only"
            ;;
        ubuntu)
            ! is_ubuntu || return 1
            label="Ubuntu only"
            ;;
        *)
            echo "$step: STEP_OS is $os, not macos or ubuntu." >&2
            return 2
            ;;
    esac
    if [ "${3:-}" == --status ]; then
        status_item skipped "$label"
    else
        echo "$step: skipped, $label"
    fi
}

step_name() {
    case "$1" in
        */install.sh)
            local dir="${1%/install.sh}"
            echo "${dir##*/}"
            ;;
        *)
            local file="${1##*/}"
            echo "${file%.sh}"
            ;;
    esac
}

# Only when no main exists, so a test that reloads this file keeps the step's own main
if ! declare -F main > /dev/null; then
    main() {
        local skip=0 flag=""
        step_args "$@"
        ! status_requested "$@" || flag=--status
        step_os_skip "$(step_name "$_SOURCED_BY")" "${STEP_OS:-}" ${flag:+"$flag"} || skip=$?
        case "$skip" in
            0) return 0 ;;
            2) return 1 ;;
        esac
        if status_requested "$@"; then
            status
            status_result
            return
        fi
        apply
    }
fi

copy_step() {
    echo "$1"
    "$2" copy_file
}

copy_status() {
    "$1" status_file
}

_repo_path() {
    local path
    path="$(cd -- "$(dirname "$1")" && pwd)/${1##*/}"
    echo "${path#"$DOTFILES_DIR"/}"
}

# Only stdin matters: stdout may be piped, and read -p prompts on stderr
is_interactive() {
    [ -t 0 ]
}

# DOTFILES_ASSUME_YES and DOTFILES_SSH_KEY_ONLY are for throwaway test machines, so they count only
# in a VM or container, and a stray export can't approve changes on a real machine
on_test_machine() {
    systemd-detect-virt -q 2>/dev/null
}

confirm() {
    local reply
    if [ "${DOTFILES_ASSUME_YES:-}" == 1 ] && on_test_machine; then
        echo "$1 yes (DOTFILES_ASSUME_YES)"
        return 0
    fi
    is_interactive || return 1
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# Installed with apt by the homebrew step on Ubuntu
UBUNTU_COMMANDS=(cc make curl file git ps zsh lsof col unzip jq gpg)

# Where to get a missing command; the homebrew step installs most
missing_cmd_hint() {
    case "$1" in
        ssh-keygen)
            if is_macos; then
                echo "ssh-keygen is part of macOS; check your PATH."
            else
                echo "ssh-keygen isn't installed. Install it with: sudo apt install openssh-client"
            fi
            ;;
        gsettings | gnome-extensions) echo "$1 isn't installed. It needs the GNOME desktop: ubuntu-desktop." ;;
        snap) echo "snap isn't installed. Install it with: sudo apt install snapd" ;;
        go) echo "go isn't installed. Run bash setup.sh runtimes first." ;;
        *)
            if is_ubuntu && [[ " ${UBUNTU_COMMANDS[*]} " == *" $1 "* ]]; then
                echo "$1 isn't installed. Run bash setup.sh homebrew first, which installs it with apt."
            else
                echo "$1 isn't installed. Run bash setup.sh homebrew first."
            fi
            ;;
    esac
}

require_cmd() {
    command -v "$1" &>/dev/null && return 0
    echo "  $(missing_cmd_hint "$1")" >&2
    return 1
}

# No --max-time, which would cut off a large .deb on a slow link; stalls time out instead
fetch() {
    local url="$1" dest="$2" name="$3"
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --speed-limit 1 --speed-time 60 \
        --retry 3 --retry-delay 2 -o "$dest" "$url" && [ -s "$dest" ] && return 0
    echo "  Couldn't download $name." >&2
    return 1
}

# Downloads first, since a failed curl | sh runs nothing and succeeds
run_installer() {
    local shell="$1" url="$2" name="$3" installer status=0
    shift 3
    installer="$(mktemp)"
    if ! fetch "$url" "$installer" "$name"; then
        rm -f "$installer"
        return 1
    fi
    "$shell" "$installer" "$@" || status=$?
    rm -f "$installer"
    return "$status"
}

# join_lines <sep>
join_lines() {
    local line out="" sep=""
    while IFS= read -r line || [ -n "$line" ]; do
        out="$out$sep$line"
        sep="$1"
    done
    printf '%s\n' "$out"
}

# report_failed [name...]: lists what failed, and fails when anything did
report_failed() {
    [ $# -gt 0 ] || return 0
    echo "Failed: $(printf '%s\n' "$@" | join_lines ', ')" >&2
    return 1
}

# parent_dir <var> <path>: sets <var> to the path's directory, as dirname would without its fork,
# for a path with no trailing slash
parent_dir() {
    local _parent="${2%/*}"
    [ "$_parent" != "$2" ] || _parent=.
    printf -v "$1" '%s' "${_parent:-/}"
}

# Replaces a differing file without asking or backing up. Sets COPIED=true when it copies.
copy_file() {
    local src="$1" dest="$2" dir
    if [ -e "$dest" ] && cmp -s "$src" "$dest" && { [ ! -x "$src" ] || [ -x "$dest" ]; }; then
        echo "  $dest is already up to date"
        return 0
    fi
    parent_dir dir "$dest"
    mkdir -p "$dir" || return 1
    if [ -x "$src" ]; then
        replace_file "$src" "$dest" 755 x
    else
        replace_file "$src" "$dest" 644
    fi || {
        if [ $? -eq 2 ]; then
            echo "  $dest is read-only, so left it unchanged." >&2
        else
            echo "  Couldn't copy ${src#"$DOTFILES_DIR"/} to $dest, so left it unchanged." >&2
        fi
        return 1
    }
    # shellcheck disable=SC2034 # callers read it
    COPIED=true
    echo "  Copied ${src#"$DOTFILES_DIR"/} to $dest"
}

# Succeeds when the repo's value should be written: unset, already equal, or the user agrees
replace_custom_value() {
    local name="$1" current="$2" wanted="$3"
    if [ -z "$current" ] || [ "$current" == "$wanted" ] ||
        confirm "  $name is $current, not the repo's $wanted. Replace it?"; then
        return 0
    fi
    echo "  Kept your value for $name, $current. The repo's is $wanted."
    return 1
}

status_custom_value() {
    local name="$1" current="$2" wanted="$3"
    if [ "$current" == "$wanted" ]; then
        status_item ok "$name: $wanted"
    elif [ -z "$current" ]; then
        status_item missing "$name: not set; the repo's is $wanted"
    else
        status_item ok "$name: yours, $current (the repo's is $wanted)"
    fi
}

end_with_newline() {
    if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then
        printf '\n' >> "$1"
    fi
}

has_line() {
    [ -f "$2" ] && grep -qxF -- "$1" "$2"
}

append_line() {
    local line="$1" file="$2" dir
    if has_line "$line" "$file"; then
        return 0
    fi
    parent_dir dir "$file"
    mkdir -p "$dir" || return 1
    end_with_newline "$file" || return 1
    printf '%s\n' "$line" >> "$file"
}

# maybe_backup <file>: offers to copy the file to <file>.bak, or to a timestamped name when .bak
# holds something else, and never overwrites a differing backup. On failure the caller must leave
# the file as it is.
maybe_backup() {
    local file="$1" bak="$1.bak" base n=1
    [ -f "$file" ] || return 0
    if [ -e "$bak" ]; then
        ! cmp -s "$file" "$bak" || return 0
        base="$file.bak.$(date +%Y%m%d-%H%M%S)"
        bak="$base"
        while [ -e "$bak" ] && ! cmp -s "$file" "$bak"; do
            n=$((n + 1))
            bak="$base-$n"
        done
    fi
    case "${DOTFILES_BACKUP:-}" in
        no) return 0 ;;
        yes) ;;
        *) confirm "  Back up $file to $bak?" || return 0 ;;
    esac
    # The loop stopped at a backup made earlier this second
    if [ -e "$bak" ]; then
        echo "  $file is already backed up to $bak"
        return 0
    fi
    if ! cp "$file" "$bak"; then
        echo "  Couldn't back up $file to $bak, so left it unchanged." >&2
        return 1
    fi
    echo "  Backed up $file to $bak"
}

# Succeeds when a process named $1 is an ancestor of this script
running_inside() {
    local pid=$$ comm
    while [ "${pid:-0}" -gt 1 ]; do
        comm="$(ps -o comm= -p "$pid")" || return 1
        [ "${comm##*/}" == "$1" ] && return 0
        pid="$(ps -o ppid= -p "$pid" | tr -d ' ')" || return 1
    done
    return 1
}

regex_escape() {
    # shellcheck disable=SC2016 # a sed pattern, not an expansion
    printf '%s' "$1" | sed 's/[][\.*^$()+?{}|]/\\&/g'
}

# git_head_is <dir> <sha>: the .git check stops git finding a repo above a plain dir
git_head_is() {
    [ -d "$1/.git" ] && [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" == "$2" ]
}

# git_checkout_pin <dir> <remote> <sha>: fetches only the pinned commit when it's missing, as
# shallow clones need
git_checkout_pin() {
    local dir="$1" remote="$2" sha="$3"
    { git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null ||
        GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch -q --depth 1 "$remote" "$sha"; } &&
        git -C "$dir" checkout -q --detach "$sha"
}

wait_until_quit() {
    for _ in $(seq 1 20); do
        pgrep "$@" &>/dev/null || return 0
        sleep 0.5
    done
    return 1
}

# Returns nonzero if the app is still running
ensure_app_quit() {
    local app="$1" pattern
    # macOS pgrep -a matches this script's ancestors too; procps -a prints command lines, which
    # are hidden here
    pattern="$(regex_escape "$app")"
    pgrep -ax "$pattern" &>/dev/null || return 0
    if running_inside "$app"; then
        echo "  $app is running this script, so it can't be quit; skipping. Re-run this script from"
        echo "  another terminal."
        return 1
    fi
    # Quitting goes through AppleScript
    if ! is_macos; then
        echo "  $app is running and must be quit to change its settings; skipping. Quit $app and"
        echo "  re-run this script."
        return 1
    fi
    if ! confirm "  $app is running and must be quit to change its settings. Quit $app now?"; then
        echo "  $app is running; skipping. Quit $app and re-run this script."
        return 1
    fi
    osascript -e "quit app \"$app\""
    wait_until_quit -ax "$pattern" && return 0
    echo "  $app did not quit; skipping."
    return 1
}

# Succeeds when the home is unset or resolves to the default
tool_home_is() {
    local home default
    [ -n "$1" ] || return 0
    home="$(cd -P "$1" 2>/dev/null && pwd)" || home="${1%/}"
    default="$(cd -P "$2" 2>/dev/null && pwd)" || default="${2%/}"
    [ "$home" == "$default" ]
}

# json_applied <file|-> <expr>: - reads stdin. One value only: jq -e takes its status from the last
# of several. The newline ends any trailing comment in the expression.
json_applied() {
    if [ "$1" == - ]; then
        jq -s -e "length == 1 and (.[0] | ($2"$'\n'") == .)" &>/dev/null
    else
        [ -s "$1" ] && jq -s -e "length == 1 and (.[0] | ($2"$'\n'") == .)" "$1" &>/dev/null
    fi
}

# Probes stat's flavor rather than is_macos, which tests override
file_mode() {
    if stat -c %a / &>/dev/null; then
        stat -L -c %a "$1"
    else
        /usr/bin/stat -L -f %Lp "$1"
    fi
}

# replace_file [--sudo] <src> <dest> <mode> [x] [install-option...]: writes a temp file beside dest
# and renames it into place, so a script running from the old file reads on unchanged, and sudo tee
# can't cut a drop-in short. The leading dot hides the temp file from run-parts and *.conf globs.
# Follows symlinks. <mode> is a new file's: an existing one keeps its own, plus exec bits with x,
# unless <mode> starts with =. --sudo runs each command through sudo. Returns 2 when dest is
# read-only, 3 when it's a directory, which mv would move the file into, and 4 when it's a dangling
# symlink, which stat reads as 777 and mv would replace.
# shellcheck disable=SC2086 # $as is empty or sudo
replace_file() {
    local as="" src dest mode exec="" tmp target dir
    [ "$1" != --sudo ] || { as=sudo; shift; }
    src="$1" dest="$2" mode="$3"
    shift 3
    [ "${1:-}" != x ] || { exec=x; shift; }
    if $as test -L "$dest"; then
        # On a dangling link macOS's readlink -f fails and GNU's succeeds, so check the target
        if ! target="$($as readlink -f -- "$dest" 2>/dev/null)" || [ -z "$target" ] ||
            ! $as test -e "$target"; then
            return 4
        fi
        dest="$target"
    fi
    ! $as test -d "$dest" || return 3
    if $as test -e "$dest"; then
        [ -n "$as" ] || [ -w "$dest" ] || return 2
        if [ "${mode#=}" == "$mode" ]; then
            # Through sudo, since the file or its directory may be root-only
            # shellcheck disable=SC2016 # expanded by the inner bash
            mode="$($as bash -c "$(declare -f file_mode)"'; file_mode "$1"' _ "$dest")" || return 1
            [ -z "$exec" ] || mode="$(printf '%o' $((0$mode | ((0$mode & 0444) >> 2))))"
        fi
    fi
    mode="${mode#=}"
    parent_dir dir "$dest"
    tmp="$($as mktemp "$dir/.${dest##*/}.XXXXXX" 2>/dev/null)" || return 1
    if $as install -m "$mode" ${1+"$@"} "$src" "$tmp" && $as mv -f "$tmp" "$dest"; then
        return 0
    fi
    $as rm -f "$tmp"
    return 1
}

write_back() {
    local new="$1" dest="$2"
    replace_file "$new" "$dest" "$(printf '%o' $((0666 & ~0$(umask))))" || {
        if [ $? -eq 2 ]; then
            echo "  $dest is read-only, so left it unchanged. The new contents are in $new." >&2
        else
            echo "  Couldn't write $dest. The new contents are in $new." >&2
        fi
        return 1
    }
    rm -f "$new"
}

# file_contents <file>: prints the file, or nothing when it's missing; fails, saying so, when it
# can't be read, such as a dangling symlink, rather than start afresh and lose data
file_contents() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    cat -- "$1" && return 0
    echo "  Couldn't read $1, so it was left as it is." >&2
    return 1
}

# merge_file <file> <transform-fn> [reader-fn]: pipes what the reader prints (file_contents by
# default) through the transform, and writes the result when it differs from the file, after
# offering a backup. Both get the file's path, and print their own errors. Check first that the
# file needs a change, as the transform's output can differ from the file in form alone.
merge_file() {
    local file="$1" transform="$2" input tmp status=1 dir
    input="$("${3:-file_contents}" "$file")" || return 1
    tmp="$(mktemp)" || return 1
    if printf '%s\n' "$input" | "$transform" "$file" > "$tmp"; then
        if cmp -s "$tmp" "$file"; then
            status=0
        elif parent_dir dir "$file" && maybe_backup "$file" && mkdir -p "$dir"; then
            write_back "$tmp" "$file"
            return
        fi
    fi
    rm -f "$tmp"
    return "$status"
}

# A file the expression doesn't change is left untouched
json_merge() {
    local filter="$2"
    require_cmd jq || return 1
    ! json_applied "$1" "$filter" || return 0
    merge_file "$1" _json_merge_filter _json_merge_read
}

# One JSON value; {} for a missing or blank file
_json_merge_read() {
    local input values
    input="$(file_contents "$1")" || return 1
    [[ "$input" =~ [^[:space:]] ]] || input='{}'
    # jq's own error says where invalid JSON goes wrong
    if ! values="$(printf '%s\n' "$input" | jq -s length)"; then
        echo "  $1 isn't valid JSON, so it was left as it is." >&2
        return 1
    elif [ "$values" != 1 ]; then
        echo "  $1 holds $values JSON values, not one, so it was left as it is." >&2
        return 1
    fi
    printf '%s\n' "$input"
}

# Runs json_merge's filter, which it reads from json_merge's local
_json_merge_filter() {
    local out
    if ! out="$(jq "$filter")" || [ "$(jq -s length <<< "$out" 2>/dev/null)" != 1 ]; then
        echo "  Couldn't update $1 with jq." >&2
        return 1
    fi
    printf '%s\n' "$out"
}

STATUS_NEEDS_ATTENTION=false

# shellcheck source=status-format.sh
source "$DOTFILES_DIR/lib/status-format.sh"

status_item() {
    printf "  %-${STATUS_STATE_WIDTH}s %s\n" "$1" "$2"
    ! status_state_needs_attention "$1" || STATUS_NEEDS_ATTENTION=true
}

sudo_cached() {
    sudo -n true 2> /dev/null
}

# memo <var> <cmd...>: runs the command, keeping its output in <var> and its status in
# <var>_STATUS, then prints the output and returns the status. While MEMO_SCOPE is set, later calls
# in the same scope reuse them instead, so a check that runs many times runs its command once. A
# function opens a scope, or joins its caller's, by declaring:
#   local MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
# A call inside $( ) caches only in that subshell, so call it once outside one first.
MEMO_SEQ="${MEMO_SEQ:-0}"

memo() {
    local _memo_var="$1" _memo_out _memo_status=0
    shift
    if ! _memo_current "$_memo_var"; then
        _memo_out="$("$@")" || _memo_status=$?
        printf -v "$_memo_var" '%s' "$_memo_out"
        printf -v "${_memo_var}_STATUS" '%s' "$_memo_status"
        printf -v "${_memo_var}_SCOPE" '%s' "${MEMO_SCOPE:-}"
    fi
    [ -z "${!_memo_var}" ] || printf '%s\n' "${!_memo_var}"
    _memo_status="${_memo_var}_STATUS"
    return "${!_memo_status}"
}

# memo_forget <var>: the next memo call for <var> runs its command again, as after a change to
# what it reads
memo_forget() {
    unset "$1_SCOPE"
}

# Succeeds when <var> was set in the current memo scope
_memo_current() {
    local scope="$1_SCOPE"
    [ -n "${MEMO_SCOPE:-}" ] && [ "${!scope:-}" == "$MEMO_SCOPE" ]
}

# Keeps the answer fixed through a memo scope
sudo_ready() {
    memo SUDO_READY sudo_cached > /dev/null
}

# Missing parts count as 0
version_at_least() {
    local IFS=. i have_parts want_parts
    read -ra have_parts <<< "$1"
    read -ra want_parts <<< "$2"
    for ((i = 0; i < ${#want_parts[@]} || i < ${#have_parts[@]}; i++)); do
        [ "${have_parts[i]:-0}" -eq "${want_parts[i]:-0}" ] && continue
        [ "${have_parts[i]:-0}" -gt "${want_parts[i]:-0}" ]
        return
    done
}

# shellcheck source=run-bounded.sh
source "$DOTFILES_DIR/lib/run-bounded.sh"

DISK_FREE_MIN_PERCENT=10
DISK_FREE_MIN_KIB=$((10 * 1024 * 1024))

# Names and mount points can contain spaces, so columns are found around the capacity %
disk_usage() {
    local out
    out="$(run_bounded 10 df -P -k "$1" 2> /dev/null)" || return 1
    awk 'NR > 1 && match($0, / +[0-9]+% +\//) {
            n = split(substr($0, 1, RSTART - 1), f, " ")
            if (n < 4 || f[n - 2] !~ /^[0-9]+$/ || f[n] !~ /^[0-9]+$/) exit 1
            name = f[1]
            for (i = 2; i <= n - 3; i++) name = name " " f[i]
            printf "%s\t%s\t%s\t%s\n", name, f[n - 2], f[n], substr($0, RSTART + RLENGTH - 1)
            found = 1
            exit
        }
        END { exit !found }' <<< "$out"
}

status_disk_space() {
    local path usage name size free mount seen="" percent text
    for path in "$@"; do
        if ! usage="$(disk_usage "$path")"; then
            status_item unknown "Free space on $path: df couldn't read it"
            continue
        fi
        IFS=$'\t' read -r name size free mount <<< "$usage"
        # A bind mount, or a second path on the same filesystem, is the same space
        case "$seen" in *"|$name:$size|"*) continue ;; esac
        seen="$seen|$name:$size|"
        [ "$size" -gt 0 ] || continue
        percent=$((free * 100 / size))
        text="Free space on $mount: $(awk -v f="$free" -v s="$size" \
            'BEGIN { printf "%.1f GiB of %.1f GiB", f / 1048576, s / 1048576 }') ($percent%)"
        if [ "$percent" -lt "$DISK_FREE_MIN_PERCENT" ] || [ "$free" -lt "$DISK_FREE_MIN_KIB" ]; then
            status_item missing "$text, under $DISK_FREE_MIN_PERCENT% or $((DISK_FREE_MIN_KIB / 1048576)) GiB; free some up"
        else
            status_item ok "$text"
        fi
    done
}

status_check() {
    local text="$1"
    shift
    if "$@"; then
        status_item ok "$text"
    else
        status_item missing "$text"
    fi
}

# item [--sudo] [--hint <text>] <status text> <pending text> <check> <fix>. The check and the fix
# are each a function, or a command and its arguments in one string split on spaces, such as
# "apt_installed ddcutil". Declare items in one function starting with items_reset and call it
# from status and apply. The drivers take checks, as given to item, to filter by, or drive every
# item. An empty status text makes an apply-only item, which items_status leaves out.
items_reset() {
    ITEM_STATUS=()
    ITEM_PENDING=()
    ITEM_CHECK=()
    ITEM_FIX=()
    ITEM_SUDO=()
    ITEM_HINT=()
}

items_reset

item() {
    local sudo=false hint=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --sudo) sudo=true ;;
            --hint)
                hint="$2"
                shift
                ;;
            *) break ;;
        esac
        shift
    done
    if [ $# -ne 4 ]; then
        echo "item: expected <status text> <pending text> <check> <fix>, got $# arguments" >&2
        return 2
    fi
    ITEM_STATUS+=("$1")
    ITEM_PENDING+=("$2")
    ITEM_CHECK+=("$3")
    ITEM_FIX+=("$4")
    ITEM_SUDO+=("$sudo")
    ITEM_HINT+=("$hint")
}

# _items_each <fn> [check...]: calls <fn> <index> for each item the checks pick, in the order they
# were added, and stops at the first call that fails, returning its status
_items_each() {
    local fn="$1" i=0
    shift
    while [ "$i" -lt ${#ITEM_CHECK[@]} ]; do
        if _item_wanted "$i" "$@"; then
            "$fn" "$i" || return
        fi
        i=$((i + 1))
    done
}

# shellcheck disable=SC2120 # with no check functions, it drives every item
items_status() {
    _items_each _item_status "$@"
}

_item_status() {
    local state=ok text="${ITEM_STATUS[$1]}"
    [ -n "$text" ] || return 0
    _item_check "$1" || state=missing
    state="${ITEM_STATE:-$state}"
    text="$text${ITEM_DETAIL:+: $ITEM_DETAIL}"
    [ "$state" != missing ] || text="$text${ITEM_HINT[$1]:+; ${ITEM_HINT[$1]}}"
    status_item "$state" "$text"
}

# shellcheck disable=SC2120 # with no check functions, it checks every item
items_ok() {
    _items_each _item_ok "$@"
}

# A check may set ITEM_DETAIL, which status shows after its text, and ITEM_STATE, which status
# shows instead of ok or missing and the other drivers take as done when it's skipped or info.
# Variables, not output, since a check in a $( ) would lose what it caches.
_item_check() {
    ITEM_DETAIL=""
    ITEM_STATE=""
    _item_run "${ITEM_CHECK[$1]}"
}

_item_ok() {
    _item_check "$1" && return 0
    case "$ITEM_STATE" in
        skipped | info) return 0 ;;
    esac
    return 1
}

# Appends a pending sudo item to the caller's pending, and sets the caller's others for one that
# needs no sudo
_item_pending() {
    if ! _item_ok "$1"; then
        if "${ITEM_SUDO[$1]}"; then
            pending+=("${ITEM_PENDING[$1]}")
        else
            others=true
        fi
    fi
}

# shellcheck disable=SC2120 # with no check functions, it drives every item
items_apply() {
    local result=0 sudo=true
    if [ "${1:-}" == --no-sudo ]; then
        sudo=false
        shift
    fi
    _items_each _item_apply "$@"
    return "$result"
}

# Reads items_apply's sudo and result
_item_apply() {
    if { "$sudo" || ! "${ITEM_SUDO[$1]}"; } && ! _item_ok "$1"; then
        _item_run "${ITEM_FIX[$1]}" || result=1
    fi
}

# items_apply_confirmed [--done <message>] [check...]: asks for the sudo items pending, then applies
# them all, or after a no, only those that need no sudo. It opens a memo scope unless
# the caller has one, and asks once per scope: later calls reuse the answer. With nothing pending,
# prints the --done message. Returns items_apply's status. A check that runs before the question
# can read pending, the sudo changes listed so far.
# shellcheck disable=SC2120 # with no check functions, it drives every item
items_apply_confirmed() {
    local done_message="" pending=() others=false result=0
    local MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    if [ "${1:-}" == --done ]; then
        done_message="$2"
        shift 2
    fi
    _items_each _item_pending "$@"
    if [ ${#pending[@]} -eq 0 ]; then
        if ! "$others"; then
            [ -z "$done_message" ] || printf '%s\n' "$done_message"
            return 0
        fi
        items_apply --no-sudo "$@"
        return
    fi
    if ! _memo_current SUDO_ANSWER; then
        SUDO_ANSWER=no
        ! confirm_sudo_changes "${pending[@]}" || SUDO_ANSWER=yes
        # shellcheck disable=SC2034 # _memo_current reads it
        SUDO_ANSWER_SCOPE="$MEMO_SCOPE"
    fi
    if ! sudo_confirmed; then
        items_apply --no-sudo "$@"
        return
    fi
    if items_apply "$@"; then
        echo "  Applied."
    else
        result=1
        echo "  Applied the rest. Some changes failed; see the errors above." >&2
    fi
    return "$result"
}

# Succeeds once items_apply_confirmed has had a yes, which a memo scope keeps for its later calls.
# A check can call it to look at root-only state only once sudo is agreed to.
sudo_confirmed() {
    _memo_current SUDO_ANSWER && [ "$SUDO_ANSWER" == yes ]
}

_item_wanted() {
    local check="${ITEM_CHECK[$1]}"
    shift
    [ $# -eq 0 ] || has_arg "$check" "$@"
}

_item_run() {
    local cmd
    case "$1" in
        *' '*)
            read -r -a cmd <<< "$1"
            "${cmd[@]}"
            ;;
        *) "$1" ;;
    esac
}

# shown_path <path>: relative to the repo for a repo file, and starting ~/ under HOME
# shellcheck disable=SC2088 # shown, not expanded
shown_path() {
    case "$1" in
        "$DOTFILES_DIR"/*) echo "${1#"$DOTFILES_DIR"/}" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

status_file() {
    local src="$1" dest="$2" shown
    shown="$(shown_path "$dest")"
    if cmp -s "$src" "$dest"; then
        # A command the step makes executable, such as git-wt, can't run without the bit
        if [ -x "$src" ] && [ ! -x "$dest" ]; then
            status_item missing "$shown isn't executable"
        else
            status_item ok "$shown"
        fi
    elif [ -e "$dest" ]; then
        status_item missing "$shown differs from the repo's $(shown_path "$src")"
    else
        status_item missing "$shown"
    fi
}

status_require_cmd() {
    command -v "$1" &>/dev/null && return 0
    status_item unknown "$2: $(missing_cmd_hint "$1")"
    return 1
}

status_result() {
    "$STATUS_NEEDS_ATTENTION" && return 3
    return 0
}

# brew catches SIGINT and exits 130, so bash wouldn't stop on its own
interrupted_status() {
    [ "$1" -eq 129 ] || [ "$1" -eq 130 ] || [ "$1" -eq 143 ]
}
