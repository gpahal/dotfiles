# Helpers shared by the runners, their steps, and the repo's other scripts. Source it; don't run it.
# shellcheck shell=bash

# A cd to a relative dir would search an exported CDPATH and print the dir it found, so every
# script that sources this file, and the ones it runs, ignore it
unset CDPATH
DOTFILES_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOTFILES_DIR

is_macos() {
    [ "$(uname -s)" == "Darwin" ]
}

# The only Linux the steps support
is_ubuntu() {
    [ "$(uname -s)" == "Linux" ] && grep -qE '^ID="?ubuntu"?$' /etc/os-release 2>/dev/null
}

# Succeeds when the en_US.UTF-8 locale, which zsh/basic-settings.zsh sets LANG to, is installed
locale_installed() {
    locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'
}

# Succeeds when an apt package is installed (not just known, or removed with its config left)
apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Seconds apt_get waits for dpkg's lock, which unattended-upgrades holds for a while after boot
APT_LOCK_TIMEOUT=300

# Run apt-get with sudo, without prompts, waiting for dpkg's lock instead of failing at once. Only
# commands that change packages wait: apt-get update fails right away while another update holds
# the lists lock, timeout or not, so use apt_get_update for it.
# e.g. apt_get install -y ufw
apt_get() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"
}

# Tries of apt_get_update, and the seconds between them: about as long as apt_get waits
APT_UPDATE_TRIES=20
APT_UPDATE_RETRY_DELAY=15

# Succeeds when apt-get's output on stdin says another update holds the lists lock. Other errors
# name the lock too, such as "Could not open lock file ... Permission denied", and aren't worth a
# retry. The phrases are apt's English ones, so under another language apt-get fails at once.
apt_lists_locked() {
    grep -E '/var/lib/apt/lists/lock' | grep -qE 'Could not get lock|is held by|Unable to acquire'
}

# apt_get update with the arguments given, tried again while another update, such as
# apt-daily's after boot, holds the lists lock. Any other failure returns at once. The output
# shows as it comes, and a copy is kept to check for the lock. The notice of each wait goes to
# stderr, so a caller that captures apt-get's output, as add_apt_repo does, still shows it.
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

# Succeeds when a file reads exactly the content. For the root-owned files steps write, which
# anyone can read.
file_is() {
    [ "$(cat "$1" 2>/dev/null)" == "$2" ]
}

# Replace a root-owned file with a copy of a local file, with sudo, creating its directory. The
# copy goes to a temp file in the same directory, which is then renamed into place, so a failed
# write leaves the old file whole: sudo tee would cut it short, and a drop-in cut short can lose a
# setting such as PasswordAuthentication no. The temp file's leading dot keeps run-parts and
# *.conf globs from reading it. The file keeps its mode unless one is given; a new one gets 644.
# Usage: install_root_file <src> <dest> [mode]
install_root_file() {
    local src="$1" dest="$2" mode="${3:-}" dir tmp
    dir="$(dirname "$dest")"
    sudo mkdir -p "$dir" || return 1
    # Through sudo, since the file or its directory may be root-only
    if [ -z "$mode" ]; then
        mode="$(sudo bash -c "$(declare -f file_mode)"'; [ ! -e "$1" ] || file_mode "$1"' _ "$dest")" ||
            return 1
    fi
    tmp="$(sudo mktemp "$dir/.${dest##*/}.XXXXXX")" || return 1
    if sudo install -m "${mode:-644}" "$src" "$tmp" && sudo mv -f "$tmp" "$dest"; then
        return 0
    fi
    sudo rm -f "$tmp"
    return 1
}

# Write content, plus a newline, to a root-owned file, as install_root_file does
write_root_file() {
    local src status=0
    src="$(mktemp)" || return 1
    printf '%s\n' "$2" > "$src" && install_root_file "$src" "$1" || status=1
    rm -f "$src"
    return "$status"
}

# List the system changes a step still needs, and ask once before making them with sudo.
# Returns nonzero when confirm declines.
confirm_sudo_changes() {
    echo "  These need sudo:"
    printf '    - %s\n' "$@"
    confirm "  Apply them?" && return 0
    echo "  Left unchanged. Run this step from a terminal to apply them."
    return 1
}

# Fail on anything but Apple Silicon macOS and Ubuntu
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

# Warn when macOS is older than the tested release, 27, or Ubuntu's CPU isn't x86_64, the one
# setup is tested on. Setup carries on, and a package with no build for the CPU fails its step.
warn_untested_platform() {
    local arch version
    if is_macos; then
        version="$(sw_vers -productVersion 2>/dev/null)" || version=""
        case "${version%%.*}" in
            [0-9] | 1[0-9] | 2[0-6]) echo "Warning: setup is tested on macOS 27, not $version. Carrying on. A package that needs a newer macOS fails its step." >&2 ;;
        esac
        return 0
    fi
    arch="$(uname -m)"
    [ "$arch" == x86_64 ] && return 0
    echo "Warning: setup is tested on x86_64 Ubuntu, not $arch. Carrying on. A package with no $arch build fails its step." >&2
}

# Put Homebrew on PATH from whichever prefix it's installed under
load_brew() {
    local brew
    # Set by the tests' hide brew, so a step finds no Homebrew even where it's installed
    [ -z "${DOTFILES_NO_LOAD_BREW:-}" ] || return 1
    for brew in /opt/homebrew/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
        if [ -x "$brew" ]; then
            eval "$("$brew" shellenv)"
            return 0
        fi
    done
    return 1
}

# Each step runs in its own process, so pick up Homebrew even when the calling shell hasn't
command -v brew &>/dev/null || load_brew || true
# The same for the runtimes mise installs, such as the Node.js the skills step needs
MISE_SHIMS="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
if [ -d "$MISE_SHIMS" ] && [[ ":$PATH:" != *":$MISE_SHIMS:"* ]]; then
    export PATH="$MISE_SHIMS:$PATH"
fi

# Homebrew asks before installing anything with dependencies. The steps install only what they
# list, so don't ask for each one, and don't print tips about Homebrew's environment variables.
export HOMEBREW_NO_ASK=1
export HOMEBREW_NO_ENV_HINTS=1

# Flags given to a runner or a step, anywhere among its arguments. Scripts source this file
# without arguments, so "$@" is the script's. What's set here is exported, so the steps a runner
# starts get it too.
# - --status: a status report changes nothing, and that includes Homebrew's own update.
# - --quick: a status report skips its slowest checks (DOTFILES_STATUS_QUICK).
# - --backup or --no-backup answers every backup question yes or no (backup_edited, maybe_backup).
for arg in "$@"; do
    case "$arg" in
        --status) export HOMEBREW_NO_AUTO_UPDATE=1 ;;
        --quick) export DOTFILES_STATUS_QUICK=1 ;;
        --backup) export DOTFILES_BACKUP=yes ;;
        --no-backup) export DOTFILES_BACKUP=no ;;
    esac
done
unset arg

# Succeeds when --status is among the arguments. A step's main gets them all, so it reports
# wherever the flag is.
# e.g. if status_requested "$@"; then status; return $?; fi
status_requested() {
    local arg
    for arg in "$@"; do
        [ "$arg" != --status ] || return 0
    done
    return 1
}

# Check a step's arguments; a step's main calls it first. -h or --help prints the usage and exits
# 0. Any other argument but --status, --quick, --backup, and --no-backup exits 2, so a typo such
# as --stauts, or status without its dashes, can't run the step. So does --quick without --status,
# which would otherwise run the step. Steps take no other arguments.
# e.g. step_args "$@"
step_args() {
    local arg path usage
    # The step's script is the outermost file, since main runs only when the script runs directly
    path="${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}"
    path="$(CDPATH='' cd -- "$(dirname "$path")" && pwd)/${path##*/}"
    usage="Usage: bash ${path#"$DOTFILES_DIR"/} [--status [--quick]] [--backup | --no-backup]"
    for arg in "$@"; do
        case "$arg" in
            -h | --help)
                echo "$usage"
                exit 0
                ;;
        esac
    done
    for arg in "$@"; do
        case "$arg" in
            --status | --quick | --backup | --no-backup) ;;
            -*)
                echo "Unknown option: $arg" >&2
                echo "$usage" >&2
                exit 2
                ;;
            *)
                echo "Unknown argument: $arg" >&2
                echo "$usage" >&2
                exit 2
                ;;
        esac
    done
    if ! status_requested "$@" && quick_requested "$@"; then
        echo "--quick only works with --status" >&2
        echo "$usage" >&2
        exit 2
    fi
}

# Succeeds when --quick is among the arguments
quick_requested() {
    local arg
    for arg in "$@"; do
        [ "$arg" != --quick ] || return 0
    done
    return 1
}

# Succeeds when stdin is a terminal, so a question can be answered. stdout may be piped, as in
# bash setup.sh | tee log: read -p writes its question to stderr.
is_interactive() {
    [ -t 0 ]
}

# Ask a yes/no question; no unless answered yes. Always no without a terminal, except that
# DOTFILES_ASSUME_YES=1 answers yes to every question, terminal or not. That's for throwaway VMs
# and containers that test setup, never for a real machine.
confirm() {
    local reply
    if [ "${DOTFILES_ASSUME_YES:-}" == 1 ]; then
        echo "$1 yes (DOTFILES_ASSUME_YES)"
        return 0
    fi
    is_interactive || return 1
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# Commands Ubuntu needs before Homebrew (https://docs.brew.sh/Homebrew-on-Linux#requirements),
# plus zsh for the login shell, lsof for port and killport, col for MANPAGER, unzip for casks
# such as font-monaspace, and jq, which steps use to edit JSON settings even if Homebrew breaks.
# The homebrew step installs them with apt. They're listed here so missing_cmd_hint can say so.
UBUNTU_COMMANDS=(cc make curl file git ps zsh lsof col unzip jq)

# Print that a command is missing and how to get it. Every command the steps check for comes from
# the homebrew step, which installs the UBUNTU_COMMANDS with apt on Ubuntu, except ssh-keygen,
# which comes with macOS and with Ubuntu's openssh-client.
missing_cmd_hint() {
    local how=""
    if [ "$1" == ssh-keygen ]; then
        if is_macos; then
            echo "ssh-keygen is part of macOS; check your PATH."
        else
            echo "ssh-keygen isn't installed. Install it with: sudo apt install openssh-client"
        fi
        return 0
    fi
    if is_ubuntu && [[ " ${UBUNTU_COMMANDS[*]} " == *" $1 "* ]]; then
        how=", which installs it with apt"
    fi
    echo "$1 isn't installed. Run bash setup.sh homebrew first$how."
}

# Fail, saying what to do, when a prerequisite (a command another step installs) is missing. A
# step checks each one before it changes anything and fails right away (`|| return 1`), so
# run_steps lists the step.
# e.g. require_cmd mise || return 1
require_cmd() {
    command -v "$1" &>/dev/null && return 0
    echo "  $(missing_cmd_hint "$1")" >&2
    return 1
}

# Download a URL to a file. Fails, saying it couldn't download <name>, when the download does or
# the file is empty. Gives up on a server that doesn't answer, or stalls for a minute, instead of
# hanging. No --max-time, which would cut off a large .deb on a slow link. The caller removes the
# file when it fails. e.g. fetch https://example.com/foo.deb "$dir/foo.deb" "Foo's .deb"
fetch() {
    local url="$1" dest="$2" name="$3"
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --speed-limit 1 --speed-time 60 \
        --retry 3 --retry-delay 2 -o "$dest" "$url" && [ -s "$dest" ] && return 0
    echo "  Couldn't download $name." >&2
    return 1
}

# Download an install script and run it with the given shell, passing it any further arguments.
# Downloading first means a failed download fails the step, where `curl | sh` would run nothing
# and succeed. The name is for fetch's error. e.g. run_installer sh https://example.com/install.sh
# "Example's installer" -y
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

# Print stdin's lines on one line, joined by $1, e.g. join_lines ', '
join_lines() {
    local line out="" sep=""
    while IFS= read -r line || [ -n "$line" ]; do
        out="$out$sep$line"
        sep="$1"
    done
    printf '%s\n' "$out"
}

# The ids of the App Store apps a Brewfile lists, one per line. brew bundle skips the ids in
# HOMEBREW_BUNDLE_MAS_SKIP; names would split on their spaces.
mas_app_ids() {
    sed -nE 's/^[[:space:]]*mas "[^"]*", id: ([0-9]+).*/\1/p' "$1"
}

# The record of the files copy_file and copy_file_ask installed, so a later run can tell a file
# setup put there from one edited by hand since. One line per file, as sha256sum prints it:
# "<sha256>  <absolute path>". Paths may contain spaces.
INSTALLED_FILES="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/installed-files"

# Print a file's SHA-256. Reading stdin keeps sha256sum from escaping odd file names.
file_sha256() {
    local sum
    if command -v sha256sum &>/dev/null; then
        sum="$(sha256sum < "$1")" || return 1
    else
        sum="$(shasum -a 256 < "$1")" || return 1
    fi
    echo "${sum%% *}"
}

# Print the SHA-256 recorded for a destination when setup last installed it, or nothing. The
# hash takes 64 characters and two spaces, so the path starts at column 67. awk reads the path
# from the environment, since -v would expand backslashes in it.
recorded_sha256() {
    [ -f "$INSTALLED_FILES" ] || return 0
    DEST="$1" awk 'substr($0, 67) == ENVIRON["DEST"] { print substr($0, 1, 64); exit }' "$INSTALLED_FILES"
}

# Rewrite the record with "<sha>  <dest>" in place of a destination's line. The new record goes
# to a temp file in the same directory and is moved into place, so a crash can't leave it cut
# short.
_rewrite_installed() {
    local dest="$1" sha="$2" dir tmp
    dir="$(dirname "$INSTALLED_FILES")"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$dir/installed-files.XXXXXX")" || return 1
    if {
        if [ -f "$INSTALLED_FILES" ]; then
            DEST="$dest" awk 'substr($0, 67) != ENVIRON["DEST"]' "$INSTALLED_FILES"
        fi
        printf '%s  %s\n' "$sha" "$dest"
    } > "$tmp" && mv "$tmp" "$INSTALLED_FILES"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Record a destination's current hash, replacing its line
record_installed() {
    local sha
    sha="$(file_sha256 "$1")" || return 1
    _rewrite_installed "$1" "$sha" && return 0
    echo "  Couldn't record $1 in $INSTALLED_FILES." >&2
    return 1
}

# Succeeds when a file is what setup last installed there: its hash matches the record. Fails
# when it was edited by hand since, or was never recorded.
installed_unedited() {
    local sha
    [ -f "$1" ] || return 1
    # A file that can't be read hashes to "", which would match a missing record
    sha="$(file_sha256 "$1" 2>/dev/null)" && [ -n "$sha" ] || return 1
    [ "$sha" == "$(recorded_sha256 "$1")" ]
}

# copy_file and copy_file_ask's shared steps. Prints whether dest is up to date and returns 0
# when it is, recording it if it isn't recorded yet. Returns 1 when dest needs copying, and 2
# when it's up to date but that record couldn't be written: a later run would take the
# unrecorded file for an edit.
_copy_up_to_date() {
    local src="$1" dest="$2"
    if [ ! -e "$dest" ] || ! cmp -s "$src" "$dest"; then
        return 1
    fi
    installed_unedited "$dest" || record_installed "$dest" || return 2
    echo "  $dest is already up to date"
}

# Each command is checked, since a caller may run this under || or if, where set -e is off
_copy_and_record() {
    local src="$1" dest="$2"
    mkdir -p "$(dirname "$dest")" || return 1
    cp "$src" "$dest" || return 1
    record_installed "$dest" || return 1
    echo "  Copied ${src#"$DOTFILES_DIR"/} to $dest"
}

# Copy a file, creating the destination directory, and record it. A file that already matches is
# left alone. One that differs is replaced: silently when it's what setup last installed, and
# after backup_edited otherwise. Fails, leaving it, when that backup does.
copy_file() {
    local src="$1" dest="$2" up_to_date=0
    _copy_up_to_date "$src" "$dest" || up_to_date=$?
    case "$up_to_date" in
        0) return 0 ;;
        2) return 1 ;;
    esac
    if [ -e "$dest" ] && ! installed_unedited "$dest"; then
        backup_edited "$dest" || return 1
    fi
    _copy_and_record "$src" "$dest"
}

# Back up a file edited by hand before setup replaces it. --backup or --no-backup
# (DOTFILES_BACKUP) decides; otherwise ask with a terminal, and back up without one, since the
# edit would be lost.
backup_edited() {
    local file="$1" bak
    [ -f "$file" ] || return 0
    bak="$(backup_path "$file")"
    case "${DOTFILES_BACKUP:-}" in
        no) return 0 ;;
        yes) ;;
        *)
            if is_interactive &&
                ! confirm "  $file was changed since setup installed it, and will be replaced. Back it up to $bak first?"; then
                return 0
            fi
            ;;
    esac
    backup_file "$file" "$bak"
}

# Print where backup_file backs a file up: <file>.bak, unless that holds something else, then
# <file>.bak.<timestamp>, adding -2, -3, ... until the name is free or holds the same content, as
# the skills step's backups do
backup_path() {
    local bak="$1.bak" base n=1
    if [ -e "$bak" ] && ! cmp -s "$1" "$bak"; then
        base="$1.bak.$(date +%Y%m%d-%H%M%S)"
        bak="$base"
        while [ -e "$bak" ] && ! cmp -s "$1" "$bak"; do
            n=$((n + 1))
            bak="$base-$n"
        done
    fi
    echo "$bak"
}

# Copy a file to the path given second, or else to backup_path's. Never copies over an existing
# file that differs: it picks backup_path's name instead, so no older backup is overwritten. Sets
# BACKUP_PATH to the backup. Fails when the copy does; the caller must then leave the file as it is.
backup_file() {
    local file="$1" bak="${2:-}"
    if [ -z "$bak" ] || { [ -e "$bak" ] && ! cmp -s "$file" "$bak"; }; then
        bak="$(backup_path "$file")"
    fi
    # shellcheck disable=SC2034 # callers read it
    BACKUP_PATH="$bak"
    if cmp -s "$file" "$bak"; then
        echo "  $file is already backed up to $bak"
        return 0
    fi
    if ! cp "$file" "$bak"; then
        echo "  Couldn't back up $file to $bak, so left it unchanged." >&2
        return 1
    fi
    echo "  Backed up $file to $bak"
}

# Like copy_file, but for files that may hold changes made by hand, such as settings an app also
# edits. One that differs and isn't what setup last installed is replaced only when the user
# agrees, and left alone without a terminal. Agreeing backs it up too, without a second question,
# unless --no-backup is set. Fails, leaving it, when that backup does.
copy_file_ask() {
    local src="$1" dest="$2" up_to_date=0
    _copy_up_to_date "$src" "$dest" || up_to_date=$?
    case "$up_to_date" in
        0) return 0 ;;
        2) return 1 ;;
    esac
    if [ -s "$dest" ] && ! installed_unedited "$dest"; then
        if ! confirm "  $dest differs from ${src#"$DOTFILES_DIR"/}. Replace it?"; then
            echo "  Left $dest unchanged. Merge ${src#"$DOTFILES_DIR"/} into it by hand."
            return 0
        fi
        if [ "${DOTFILES_BACKUP:-}" != no ]; then
            backup_file "$dest" || return 1
        fi
    fi
    _copy_and_record "$src" "$dest"
}

# A setting you can change yourself, such as mise's global node, is one setup sets when it's unset.
# When it holds a value of your own, setup asks each run whether to replace it with the repo's,
# and keeps yours on no. Without a terminal it keeps yours, unless DOTFILES_ASSUME_YES=1 answers
# yes. Succeeds when the repo's value should be written: the setting is unset, already the repo's,
# or the answer is yes. An empty value means unset.
# e.g. if replace_custom_value "mise's global node" "$current" lts; then ...; fi
replace_custom_value() {
    local name="$1" current="$2" wanted="$3"
    if [ -z "$current" ] || [ "$current" == "$wanted" ] ||
        confirm "  $name is $current, not the repo's $wanted. Replace it?"; then
        return 0
    fi
    echo "  Kept your value for $name, $current. The repo's is $wanted."
    return 1
}

# Print a status item for a setting replace_custom_value manages: ok when it's the repo's value,
# ok naming yours when you set your own, which setup keeps, and missing when it's unset
# e.g. status_custom_value "mise's global node" "$current" lts
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

# End a file with a newline if its last line has none, so text appended next starts a new line
end_with_newline() {
    if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then
        printf '\n' >> "$1"
    fi
}

# Succeeds when a file has a line, whole
has_line() {
    [ -f "$2" ] && grep -qxF -- "$1" "$2"
}

# Append a line to a file unless it's already there. Fails only when the file can't be written;
# a caller that says whether anything changed checks has_line first.
append_line() {
    local line="$1" file="$2"
    if has_line "$line" "$file"; then
        return 0
    fi
    mkdir -p "$(dirname "$file")" || return 1
    end_with_newline "$file" || return 1
    printf '%s\n' "$line" >> "$file"
}

# Before editing an existing file, ask whether to back it up, unless <file>.bak already matches
# it. The backup goes where backup_file puts it, so an older, different .bak is kept. --backup or
# --no-backup (DOTFILES_BACKUP) answers for you. Fails when the backup does; the caller must then
# leave the file as it is.
maybe_backup() {
    local bak
    [ -f "$1" ] || return 0
    cmp -s "$1" "$1.bak" && return 0
    bak="$(backup_path "$1")"
    case "${DOTFILES_BACKUP:-}" in
        no) return 0 ;;
        yes) ;;
        *) confirm "  Back up $1 to $bak?" || return 0 ;;
    esac
    backup_file "$1" "$bak"
}

# Succeeds when this script runs inside an app, e.g. in its built-in terminal
running_inside() {
    local pid=$$ comm
    while [ "${pid:-0}" -gt 1 ]; do
        comm="$(ps -o comm= -p "$pid")" || return 1
        [ "${comm##*/}" == "$1" ] && return 0
        pid="$(ps -o ppid= -p "$pid" | tr -d ' ')" || return 1
    done
    return 1
}

# Quit a running app (after asking). Returns non-zero if it is still running.
ensure_app_quit() {
    local app="$1" pattern
    # pgrep takes a regex, so escape app names. On macOS, -a counts this script's ancestors too;
    # procps's -a only lists full command lines, which the redirect hides.
    # shellcheck disable=SC2016 # a sed pattern, not an expansion
    pattern="$(printf '%s' "$app" | sed 's/[][\.*^$()+?{}|]/\\&/g')"
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
    for _ in $(seq 1 20); do
        pgrep -ax "$pattern" &>/dev/null || return 0
        sleep 0.5
    done
    echo "  $app did not quit; skipping."
    return 1
}

# Install a Homebrew cask unless it, or the path it installs, is already there. Fails, saying
# how to get brew, when it's missing.
install_cask() {
    local cask="$1" from
    require_cmd brew || return 1
    IFS=$'\t' read -r from _ <<< "$(cask_state "$cask" "${2:-}")"
    case "$from" in
        brew) echo "  $cask already installed." ;;
        gone)
            echo "  brew lists $cask, but its app is gone; reinstalling it..."
            brew reinstall --cask "$cask"
            ;;
        # brew install would fail on the existing app, and `upgrade` skips casks brew doesn't list
        other) echo "  $cask already installed, but not by Homebrew, so upgrade won't update it." ;;
        *)
            echo "  Installing $cask..."
            brew install --cask "$cask"
            ;;
    esac
}

# jq for the path of the app each cask in brew info --json=v2's output installs, or "" for a cask
# with no app, such as a font or one that runs an installer
CASK_APP_JQ='[.artifacts[] | objects | select(has("app")) | .target // ("/Applications/" + .app[0])][0] // ""'

# Print the path of the app a Homebrew cask installs, e.g. /Applications/Claude.app
cask_app_path() {
    brew info --json=v2 --cask "$1" 2>/dev/null | jq -r ".casks[0] | $CASK_APP_JQ"
}

# Print the app path installed_cask_apps's output gives for a cask, failing when it isn't listed
# e.g. app="$(listed_cask_app raycast "$apps")"
listed_cask_app() {
    printf '%s\n' "$2" | awk -F '\t' -v cask="$1" '$1 == cask { print $2; found = 1 } END { exit !found }'
}

# The app each cask that runs an installer puts in place, as <cask>=<path>. brew's metadata lists
# no app for them.
CASK_PKG_APPS=("tailscale-app=/Applications/Tailscale.app" "logi-options+=/Applications/logioptionsplus.app")

# cask_state <cask> [<app>] [<listing>]: print how a Homebrew cask is installed, a tab, and the
# path of the app it installs: "brew" when brew lists it, "gone" when brew lists it but its app was
# deleted (macOS only), "other" when brew doesn't list it but the app is there, as when an app
# that auto-updates was installed outside brew, or "missing". <app> is the path the caller expects
# the app at, used when brew names none. <listing> is installed_cask_apps's output, which saves a
# brew call per cask; without it, brew is asked about this cask. Off macOS brew names no path, so
# a listed cask is never gone.
# e.g. IFS=$'\t' read -r state app <<< "$(cask_state raycast "" "$apps")"
cask_state() {
    local cask="$1" app="" listed=false entry state
    if [ $# -ge 3 ]; then
        if app="$(listed_cask_app "$cask" "$3")"; then
            listed=true
        fi
    elif brew list --cask "$cask" &>/dev/null; then
        listed=true
        if is_macos; then
            app="$(cask_app_path "$cask")"
        fi
    fi
    if [ -z "$app" ] && { is_macos || ! "$listed"; }; then
        app="${2:-}"
    fi
    if is_macos && [ -z "$app" ]; then
        for entry in ${CASK_PKG_APPS[@]+"${CASK_PKG_APPS[@]}"}; do
            [ "${entry%%=*}" != "$cask" ] || app="${entry#*=}"
        done
        if [ -z "$app" ] && ! "$listed"; then
            app="$(cask_app_path "$cask" || true)"
        fi
    fi
    if "$listed"; then
        if [ -n "$app" ] && [ ! -e "$app" ]; then state=gone; else state=brew; fi
    elif [ -n "$app" ] && [ -e "$app" ]; then
        state=other
    else
        state=missing
    fi
    printf '%s\t%s\n' "$state" "$app"
}

# Succeeds when a tool's home, from its environment variable, is unset or names the default
# directory, however it's spelled. The AI tool steps only write to the default (see ai_tools/README.md
# → Automated setup).
# e.g. tool_home_is "${CODEX_HOME:-}" "$HOME/.codex"
tool_home_is() {
    local home default
    [ -n "$1" ] || return 0
    home="$(cd -P "$1" 2>/dev/null && pwd)" || home="${1%/}"
    default="$(cd -P "$2" 2>/dev/null && pwd)" || default="${2%/}"
    [ "$home" == "$default" ]
}

# Succeeds when a jq expression wouldn't change a JSON file, i.e. its settings are already there
json_applied() {
    [ -s "$1" ] && jq -e "($2) == ." "$1" &>/dev/null
}

# Print the HTTP status of a HEAD request for a URL: 200 when it's there, 404 when it isn't, and
# 000 when its host can't be reached
http_status() {
    curl -sIL --connect-timeout 15 --max-time 30 -o /dev/null -w '%{http_code}' "$1" || true
}

# Print what's wrong with an apt source file a step owns, or nothing when it reads exactly what the
# step writes: "missing", or "differs from what setup writes", as when a release upgrade comments
# it out, adds Enabled: no, or leaves the old release's suite
# e.g. apt_source_state "$DOCKER_SOURCES" "$(docker_sources)"
apt_source_state() {
    if [ ! -e "$1" ]; then
        echo missing
    elif ! file_is "$1" "$2"; then
        echo "differs from what setup writes"
    fi
}

# Report an apt source file a step owns, as apt_source_state judges it. A re-run fixes it only once
# the repo publishes packages for this release (apt_repo_published).
# e.g. status_apt_source Docker "$DOCKER_SOURCES" "$(docker_sources)" docker "$(docker_release_url)"
status_apt_source() {
    local state
    state="$(apt_source_state "$2" "$3")"
    if [ -z "$state" ]; then
        status_item ok "$1's apt source ($2)"
    elif [ "$(http_status "$5")" == 404 ]; then
        status_item missing "$1's apt source ($2): $state; $1 hasn't published packages for Ubuntu $(ubuntu_codename) yet"
    else
        status_item missing "$1's apt source ($2): $state; re-run the $4 step"
    fi
}

# Whether a repo has published packages for this release: its release check URL (the repo's Release
# file for this release) isn't a 404, as it is for a while after a release upgrade. Nothing a step
# does fixes that, so when it hasn't, this says to wait, and the step leaves the repo alone without
# asking for sudo.
# e.g. apt_repo_published Docker "$(docker_release_url)"
apt_repo_published() {
    [ "$(http_status "$2")" != 404 ] && return 0
    echo "  $1 hasn't published packages for Ubuntu $(ubuntu_codename) yet; re-run this step later."
    return 1
}

# Put back an apt key from the copy at $1, or remove the key at $2 when $1 is empty, since there
# was none before
restore_apt_key() {
    if [ -n "$1" ]; then
        install_root_file "$1" "$2" 0644
    else
        sudo rm -f "$2"
    fi
}

# What add_apt_repo returns when the repo has no packages for this release yet
APT_REPO_UNPUBLISHED=3

# Add a third-party apt repo whose source file a step owns: install its key, write the source when
# its content differs, and update from that file alone, so a failure is the repo's. A source apt
# can't use fails every later apt-get update, so on failure the previous source and key come
# back, or the new ones go. Returns APT_REPO_UNPUBLISHED, changing nothing, when the repo hasn't
# published packages for this release (apt_repo_published), so its caller waits rather than fails.
# Callers check that first too, to ask for nothing they can't do. Run it as
# `add_apt_repo ... || ...`, where set -e is off, so each command checks its own failure.
# e.g. add_apt_repo Docker "$DOCKER_SOURCES" "$(docker_sources)" "$DOCKER_KEY_URL" "$DOCKER_KEYRING" "$(docker_release_url)"
add_apt_repo() {
    local name="$1" file="$2" content="$3" key_url="$4" keyring="$5" release_url="$6"
    local key old_key="" output="" previous="" reason=""
    apt_repo_published "$name" "$release_url" || return "$APT_REPO_UNPUBLISHED"
    # Read the source to restore before the key changes, so failing to read it changes nothing
    if [ -e "$file" ]; then
        previous="$(sudo cat "$file")" || return 1
    fi
    key="$(mktemp)" || return 1
    if [ -e "$keyring" ] && ! { old_key="$(mktemp)" && cp "$keyring" "$old_key"; }; then
        rm -f "$key" "$old_key"
        return 1
    fi
    if ! fetch "$key_url" "$key" "$name's apt key" ||
        ! sudo install -m 0755 -d "$(dirname "$keyring")"; then
        rm -f "$key" "$old_key"
        return 1
    fi
    # A failed write leaves the old key
    if ! install_root_file "$key" "$keyring" 0644; then
        rm -f "$key" "$old_key"
        return 1
    fi
    rm -f "$key"
    # A failed write leaves the old source, but the key has changed, so it gets the same rollback
    # as a failed update. --error-on=any fails on a key apt can't verify, which apt-get update
    # otherwise only warns about. A lists lock another update still holds after apt_get_update's
    # tries says nothing about this source.
    if ! file_is "$file" "$content" && ! write_root_file "$file" "$content"; then
        reason="Writing $file failed"
    else
        echo "  Updating apt's lists for $name (this waits while another apt update holds the lock)..."
        if ! output="$(apt_get_update --error-on=any -o Dir::Etc::sourcelist="$file" \
            -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)"; then
            printf '%s\n' "$output" >&2
            reason="apt-get update failed with the new $file alone"
            # The new file and the key it names stay then
            if apt_lists_locked <<< "$output"; then
                echo "  Another apt-get update holds apt's lock, so $file was kept. Re-run once it finishes." >&2
                rm -f "$old_key"
                return 1
            fi
        fi
    fi
    if [ -n "$reason" ]; then
        if [ -n "$previous" ]; then
            if write_root_file "$file" "$previous"; then
                echo "  $reason, so the old one is back. Fix the error above and re-run." >&2
            else
                echo "  $reason, and putting the old one back failed too. Fix $file by hand, or delete it, then re-run." >&2
            fi
        elif sudo rm -f "$file"; then
            echo "  $reason, so it was removed. Fix the error above and re-run." >&2
        else
            echo "  $reason, and removing it failed too. Delete $file by hand, then re-run." >&2
        fi
        if ! restore_apt_key "$old_key" "$keyring"; then
            echo "  Couldn't put $name's old key back at $keyring. Re-run to install it again." >&2
        fi
        rm -f "$old_key"
        return 1
    fi
    rm -f "$old_key"
    printf '%s\n' "$output"
}

# Print this Ubuntu release's codename, such as resolute, which apt sources name as their suite
ubuntu_codename() {
    (
        # shellcheck source=/dev/null
        . "${OS_RELEASE:-/etc/os-release}" 2>/dev/null || true
        echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    )
}

# Succeeds for an APT::Periodic interval that makes apt.systemd.daily run a job at least daily:
# always, or a number of s, m, h, or d, which a bare number means, from 1 s to a day
periodic_daily() {
    local number="${1%[smhd]}" unit=d
    [ "$1" != always ] || return 0
    [ "$number" == "$1" ] || unit="${1#"$number"}"
    # Up to nine digits, so the seconds can't overflow
    [[ "$number" =~ ^[0-9]{1,9}$ ]] || return 1
    number=$((10#$number))
    case "$unit" in
        m) number=$((number * 60)) ;;
        h) number=$((number * 3600)) ;;
        d) number=$((number * 86400)) ;;
    esac
    [ "$number" -gt 0 ] && [ "$number" -le 86400 ]
}

# Read the values the way apt.systemd.daily does, with apt-config shell and its defaults: Enable is
# 1, so only 0 turns it off, and the two intervals are 0.
unattended_upgrades_on() {
    local values enable=1 update=0 upgrade=0
    values="$(apt-config shell enable APT::Periodic::Enable update APT::Periodic::Update-Package-Lists \
        upgrade APT::Periodic::Unattended-Upgrade 2>/dev/null)" || return 1
    # apt-config quotes each value for the shell
    eval "$values"
    ! [[ "$enable" =~ ^0+$ ]] && periodic_daily "$update" && periodic_daily "$upgrade"
}

# Print a file's permission bits in octal, e.g. 644. It asks stat which form it takes rather than
# using is_macos, which tests override: GNU stat (Ubuntu, or coreutils on macOS) takes -c, and
# macOS's own takes -f.
file_mode() {
    if stat -c %a / &>/dev/null; then
        stat -c %a "$1"
    else
        /usr/bin/stat -f %Lp "$1"
    fi
}

# Replace a file's contents with a temp file's, then remove the temp file. The contents go to a new
# file in the same directory, given the old one's mode, which is then moved into place, so a full
# disk can't leave the file cut short. A symlink's target is replaced the same way, so the link
# stays. Fails, keeping the temp file and saying where it is, when the write does.
write_back() {
    local new="$1" dest="$2" tmp mode="" target
    if [ -L "$dest" ]; then
        # macOS's readlink and GNU's both take -f, and follow every link in the chain
        if ! target="$(readlink -f -- "$dest" 2>/dev/null)" || [ -z "$target" ]; then
            echo "  Couldn't write $dest. The new contents are in $new." >&2
            return 1
        fi
        dest="$target"
    fi
    if [ -e "$dest" ]; then
        mode="$(file_mode "$dest")" || mode=""
    fi
    if tmp="$(mktemp "$(dirname "$dest")/.${dest##*/}.XXXXXX" 2>/dev/null)" &&
        cat "$new" > "$tmp" &&
        # mktemp makes it 600. A new file gets the mode umask gives it.
        chmod "${mode:-$(printf '%o' $((0666 & ~0$(umask))))}" "$tmp" &&
        mv -f "$tmp" "$dest"; then
        rm -f "$new"
        return 0
    fi
    [ -z "${tmp:-}" ] || rm -f "$tmp"
    echo "  Couldn't write $dest. The new contents are in $new." >&2
    return 1
}

# Merge a jq expression into a JSON file, creating the file if needed
json_merge() {
    local file="$1" filter="$2" tmp input=""
    require_cmd jq || return 1
    # A missing, empty, or whitespace-only file starts as {}. One that can't be read, such as a
    # dangling symlink, fails rather than start from {} and lose what it holds. Back up and write
    # nothing until jq succeeds with one JSON value, so a filter that fails, or yields no value or
    # several, leaves the file as it was and asks nothing.
    if [ -e "$file" ] || [ -L "$file" ]; then
        if ! input="$(cat -- "$file")"; then
            echo "  Couldn't read $file, so it was left as it is." >&2
            return 1
        fi
    fi
    [[ "$input" =~ [^[:space:]] ]] || input='{}'
    tmp="$(mktemp)"
    if ! printf '%s\n' "$input" | jq "$filter" > "$tmp" || [ "$(jq -s length "$tmp" 2>/dev/null)" != 1 ]; then
        echo "  Couldn't update $file with jq." >&2
        rm -f "$tmp"
        return 1
    fi
    if ! maybe_backup "$file"; then
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$file")"
    write_back "$tmp" "$file"
}

# Print a section of a Markdown doc for the terminal: the lines under the last of the given
# headings, each found inside the one before, up to the next heading at the same level or above.
# Links shrink to their text, plus where they point: the URL for a web link, and for a link into
# the repo, the doc's path, as text (see <doc>) (doc_links). The manual-steps scripts print their
# lists from the READMEs this way, so the docs are the only copy. Fails when a heading is missing.
# e.g. print_doc_section README.md "## Manual steps" "### Ubuntu"
print_doc_section() {
    local file="$1" text
    shift
    # The headings go through the environment, since awk -v would expand backslashes in them
    text="$(HEADINGS="$(printf '%s\t' "$@")" awk '
        BEGIN { n = split(ENVIRON["HEADINGS"], want, "\t") - 1 }
        /^```/ { fence = !fence }
        !fence && /^#+ / {
            level = index($0, " ") - 1
            if (depth > 0 && level <= levels[depth]) exit
            if (depth < n && $0 == want[depth + 1]) { levels[++depth] = level; next }
        }
        depth == n {
            if ($0 == "") { if (printed) blanks++; next }
            for (; blanks > 0; blanks--) print ""
            print "  " $0
            printed = 1
        }
        END { exit !printed }
    ' "$file")" || {
        echo "  Couldn't find \"$*\" in $file." >&2
        return 1
    }
    printf '%s\n' "$text" | doc_links "$file" | sed -E \
        -e 's/\[([^]]*)\]\((https?:[^)]*)\)/\1 (\2)/g' \
        -e 's/\*\*//g'
}

# Rewrite the links in Markdown text read from stdin that point into the repo, for the terminal:
# [text](<path>#<anchor>) becomes text (see <doc>), with <doc> the path, relative to the repo, of
# the doc it points to, which is the doc the text comes from when the link has only an anchor.
# Web links stay.
# Usage: doc_links <doc the text comes from>
doc_links() {
    # Paths go through the environment, since awk -v would expand backslashes in them
    DOC="$1" ROOT="$DOTFILES_DIR" awk '
        # A path with its . and .. parts resolved
        function clean(path, parts, n, i, out, k) {
            n = split(path, parts, "/")
            k = 0
            for (i = 1; i <= n; i++) {
                if (parts[i] == "." || (parts[i] == "" && i > 1)) continue
                if (parts[i] == ".." && k > 1) { k--; continue }
                out[++k] = parts[i]
            }
            path = out[1]
            for (i = 2; i <= k; i++) path = path "/" out[i]
            return path
        }
        BEGIN {
            doc = clean(ENVIRON["DOC"])
            root = clean(ENVIRON["ROOT"])
            dir = doc
            if (!sub(/\/[^\/]*$/, "", dir)) dir = "."
        }
        {
            line = $0
            out = ""
            while (match(line, /\[[^]]*\]\([^)]*\)/)) {
                link = substr(line, RSTART, RLENGTH)
                out = out substr(line, 1, RSTART - 1)
                line = substr(line, RSTART + RLENGTH)
                text = link
                sub(/\]\(.*/, "", text)
                text = substr(text, 2)
                target = link
                sub(/^\[[^]]*\]\(/, "", target)
                sub(/\)$/, "", target)
                if (target ~ /^[a-z]+:/) { out = out link; continue }
                sub(/#.*/, "", target)
                path = target == "" ? doc : clean(dir "/" target)
                if (index(path, root "/") == 1) path = substr(path, length(root) + 2)
                out = out text " (see " path ")"
            }
            print out line
        }
    '
}

# Set once status_item prints an item that needs attention
STATUS_NEEDS_ATTENTION=false

# Print one item of a step's --status report. States:
#   ok          set up
#   missing     not set up; running the step (or the manual step it names) sets it up
#   skipped     doesn't apply here, such as on the other OS or in a VM; say why
#   unverified  looks set up, but the rest wasn't checked, e.g. without sudo or under --quick; say
#               why. Unlike missing and unknown, it doesn't need attention.
#   unknown     can't be checked, e.g. because a tool is missing or a download failed; say why
#   info        a value to know rather than something setup sets up, such as whether FileVault is
#               on, or that such a check couldn't run; it doesn't need attention
# e.g. status_item missing "~/.zshrc sources main.zsh"
status_item() {
    printf '  %-10s %s\n' "$1" "$2"
    case "$1" in
        missing | unknown) STATUS_NEEDS_ATTENTION=true ;;
    esac
}

# Succeeds when sudo credentials are cached, so sudo -n runs without asking for a password. A
# status function may read root-only settings with sudo -n when it does, and never asks.
sudo_cached() {
    sudo -n true 2> /dev/null
}

# Run an external command, stopping it after <seconds> with exit status 124, as timeout(1) does.
# For a status check that can hang, such as smartctl on a failing disk. With timeout(1), a command
# that ignores SIGTERM gets SIGKILL 5 s later. macOS has no timeout(1), so there perl sets an alarm
# and execs the command, which SIGALRM then stops. That stops only the command, not what it
# started, which is enough for its macOS callers (fdesetup, socketfilterfw, and df), which start
# nothing. Without perl either, the command runs unbounded.
# e.g. run_bounded 30 docker system df
run_bounded() {
    local seconds="$1" status=0 start=$SECONDS
    shift
    if command -v timeout &>/dev/null; then
        timeout -k 5 "$seconds" "$@" || status=$?
        # timeout(1) exits 137 when it had to send SIGKILL. A command killed some other way
        # before the deadline keeps its 137.
        if [ "$status" -eq 137 ] && [ $((SECONDS - start)) -ge "$seconds" ]; then
            status=124
        fi
        return "$status"
    fi
    if ! command -v perl &>/dev/null; then
        "$@"
        return
    fi
    # exec's block form runs the command without a shell, whatever its arguments hold. The alarm
    # outlives exec.
    perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' "$seconds" "$@" || status=$?
    # 142 is death by SIGALRM. A command killed that way before the deadline keeps it.
    if [ "$status" -eq 142 ] && [ $((SECONDS - start)) -ge "$seconds" ]; then
        status=124
    fi
    return "$status"
}

# Free space below either floor needs attention: a full disk stops builds, Docker, and updates,
# and the exit code 3 lets a scheduled status run notice
DISK_FREE_MIN_PERCENT=10
DISK_FREE_MIN_KIB=$((10 * 1024 * 1024))

# Print "<filesystem>\t<size KiB>\t<free KiB>\t<mount point>" for the filesystem a path is on,
# from POSIX df output, which macOS and GNU df print alike. The filesystem's name and the mount
# point can have spaces, so the columns are found around the capacity, the only one ending in %.
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

# Print an item for the free space on the filesystem each path is on, once per filesystem: missing
# under DISK_FREE_MIN_PERCENT or DISK_FREE_MIN_KIB free, and unknown when df can't read it
# e.g. status_disk_space / "$HOME"
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

# Print an ok or missing item for whether a check succeeds. Describe the state it checks for.
# e.g. status_check "rustup installed" rustup_installed
status_check() {
    local text="$1"
    shift
    if "$@"; then
        status_item ok "$text"
    else
        status_item missing "$text"
    fi
}

# Print an item for whether an installed file still matches its source in the repo, and is
# executable when the source is. A file that differs is missing, and the item says why: the
# repo has a newer version (the copy is what setup last installed), the installed copy was
# edited, or there is no installation record.
# A changed or unrecorded copy gets how to fix it, for steps that won't replace it themselves.
# e.g. status_file "$DOTFILES_DIR/zed/keymap.json" ~/.config/zed/keymap.json "merge by hand"
status_file() {
    local src="$1" dest="$2" fix="${3:-}" shown="$2"
    # shellcheck disable=SC2088 # shown, not expanded
    [[ "$dest" == "$HOME/"* ]] && shown="~/${dest#"$HOME"/}"
    if cmp -s "$src" "$dest"; then
        # A command the step makes executable, such as git-wt, can't run without the bit
        if [ -x "$src" ] && [ ! -x "$dest" ]; then
            status_item missing "$shown isn't executable"
        else
            status_item ok "$shown"
        fi
    elif installed_unedited "$dest"; then
        status_item missing "$shown differs from ${src#"$DOTFILES_DIR"/}: the repo has a newer version"
    elif [ -e "$dest" ]; then
        if [ -n "$(recorded_sha256 "$dest")" ]; then
            status_item missing "$shown was edited since setup installed it${fix:+; $fix}"
        else
            status_item missing "$shown differs, and setup has no record of installing it${fix:+; $fix}"
        fi
    else
        status_item missing "$shown"
    fi
}

# Print an unknown item, saying what to do, when a command another step installs is missing, and
# fail. Run the checks that need the command only when it succeeds.
# e.g. status_require_cmd gh "GitHub login" && status_github_login
status_require_cmd() {
    command -v "$1" &>/dev/null && return 0
    status_item unknown "$2: $(missing_cmd_hint "$1")"
    return 1
}

# Print an item for whether a Homebrew cask, or the path it installs, is there, given cask_state's
# arguments. Without brew, say so rather than report the cask missing.
status_cask() {
    local state
    status_require_cmd brew "$1 (cask)" || return 0
    IFS=$'\t' read -r state _ <<< "$(cask_state "$@")"
    case "$state" in
        brew) status_item ok "$1 (cask)" ;;
        gone) status_item missing "$1 (cask): brew lists it, but its app is gone; run brew reinstall --cask $1" ;;
        other) status_item ok "$1 (cask), installed outside Homebrew" ;;
        *) status_item missing "$1 (cask)" ;;
    esac
}

# A step's status function returns this: 3 when any item needs attention, otherwise 0
status_result() {
    "$STATUS_NEEDS_ATTENTION" && return 3
    return 0
}

# Read a runner's arguments: flags and step names, in any order. Sets RUNNER_MODE to --status or
# "", and RUNNER_STEPS to the step names. -h or --help prints the caller's usage function and
# exits; an unknown flag, or --quick without --status, prints it and exits 2. The loop above
# already read the other flags.
# e.g. runner_args "$@"; run_steps "$RUNNER_MODE" ${RUNNER_STEPS[@]+"${RUNNER_STEPS[@]}"}
# shellcheck disable=SC2034 # the runners read RUNNER_MODE
runner_args() {
    local arg
    RUNNER_MODE=""
    RUNNER_STEPS=()
    for arg in "$@"; do
        case "$arg" in
            -h | --help)
                usage
                exit 0
                ;;
        esac
    done
    for arg in "$@"; do
        case "$arg" in
            --status) RUNNER_MODE=--status ;;
            --quick | --backup | --no-backup) ;;
            -*)
                echo "Unknown option: $arg" >&2
                usage >&2
                exit 2
                ;;
            *) RUNNER_STEPS+=("$arg") ;;
        esac
    done
    if [ -z "$RUNNER_MODE" ] && quick_requested "$@"; then
        echo "--quick only works with --status" >&2
        usage >&2
        exit 2
    fi
}

# Print the script of a step in the caller's MACOS_STEPS or UBUNTU_STEPS: $STEPS_DIR/manual-steps.sh
# for manual-steps, otherwise $STEPS_DIR/<step>/install.sh. Fails for any other name. Either OS's
# steps resolve, so a step named on the other OS reaches its own skip message.
step_script() {
    [ -n "$1" ] || return 1
    case " ${MACOS_STEPS[*]-} ${UBUNTU_STEPS[*]-} " in
        *" $1 "*) ;;
        *) return 1 ;;
    esac
    # shellcheck disable=SC2154 # STEPS_DIR is set by the caller
    if [ "$1" == manual-steps ]; then
        echo "$STEPS_DIR/manual-steps.sh"
    else
        echo "$STEPS_DIR/$1/install.sh"
    fi
}

# runner_main <name> [arg...]
# The runners' shared body: pick STEPS for this OS, read the arguments, then run the steps, or
# with --status their reports, under headers naming <name>. The caller sets MACOS_STEPS,
# UBUNTU_STEPS, STEPS_DIR, and a usage function. Exits with the --status result (3 when something
# needs attention, 1 when a step failed) and when a step fails; returns after a successful run.
runner_main() {
    local name="$1" status=0
    shift
    if is_macos; then
        STEPS=("${MACOS_STEPS[@]}")
    else
        STEPS=("${UBUNTU_STEPS[@]}")
    fi
    runner_args "$@"
    if [ "$RUNNER_MODE" == "--status" ]; then
        echo "=== $name status ==="
        run_steps --status ${RUNNER_STEPS[@]+"${RUNNER_STEPS[@]}"} || status=$?
        exit "$status"
    fi
    echo "=== $name setup ==="
    run_steps "" ${RUNNER_STEPS[@]+"${RUNNER_STEPS[@]}"} || exit $?
    echo ""
    echo "=== $name setup complete! ==="
}

# Say a step name is unknown, listing the steps. step_script takes either OS's, so the caller's
# MACOS_STEPS and UBUNTU_STEPS are both listed when it sets them.
unknown_step() {
    if [ -n "${MACOS_STEPS[*]-}" ] && [ -n "${UBUNTU_STEPS[*]-}" ]; then
        echo "Unknown step: $1. Steps on macOS: ${MACOS_STEPS[*]}. On Ubuntu: ${UBUNTU_STEPS[*]}" >&2
    else
        # shellcheck disable=SC2154 # STEPS is set by the caller
        echo "Unknown step: $1. Steps: ${STEPS[*]}" >&2
    fi
}

# run_steps <mode> [step...]
# Run named steps in order, each in its own process, with the script step_script prints. With no
# names, run every step in $STEPS. A failing step doesn't stop the rest; the failures are listed
# at the end with the command that re-runs them, and the run fails.
#
# With mode --status, run each step's read-only --status report instead, under a header with the
# step's name. A step whose report has missing or unknown items exits 3; those are listed at the
# end too, and the run returns 3 (or 1 when a step also failed). An empty mode runs the steps.
run_steps() {
    local mode="$1" step script status failed=() attention=()
    shift
    require_supported_os || return 1
    for step in "$@"; do
        step_script "$step" > /dev/null || {
            unknown_step "$step"
            return 1
        }
    done
    warn_untested_platform
    # shellcheck disable=SC2154 # STEPS is set by the caller
    [ $# -gt 0 ] || set -- "${STEPS[@]}"
    for step in "$@"; do
        script="$(step_script "$step")"
        status=0
        if [ -n "$mode" ]; then
            # The header goes before the step's first line, so a step that reports nothing (such
            # as manual-steps) prints nothing. fflush streams each line as it comes.
            "$BASH" "$script" --status | awk -v header="$step:" 'NR == 1 { print header } { print; fflush() }' ||
                status=$?
        else
            "$BASH" "$script" || status=$?
        fi
        # SIGHUP, SIGINT (Ctrl-C), or SIGTERM: stop. brew catches SIGINT and exits 130, so bash
        # doesn't see the signal itself and would carry on to the next step. Other codes above
        # 128, such as 141 from SIGPIPE or 255 from ssh, are failures like any other.
        if [ "$status" -eq 129 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then
            echo "  The $step step was interrupted; stopping." >&2
            return "$status"
        elif [ -n "$mode" ] && [ "$status" -eq 3 ]; then
            attention+=("$step")
        elif [ "$status" -ne 0 ]; then
            echo "  The $step step failed." >&2
            failed+=("$step")
        fi
    done
    if [ ${#attention[@]} -gt 0 ]; then
        echo ""
        echo "Needs attention: ${attention[*]}. Run: bash $0 ${attention[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        echo "" >&2
        echo "Failed steps: ${failed[*]}" >&2
        echo "Fix the errors above, then re-run them with: bash $0 ${mode:+$mode }${failed[*]}" >&2
        return 1
    fi
    [ ${#attention[@]} -eq 0 ] || return 3
}
