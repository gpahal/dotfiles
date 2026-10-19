# Helpers shared by the runners, their steps, and the repo's other scripts. Source it; don't run it.
# The APIs a step builds on, each documented where it's defined:
# - item and its drivers (items_reset, items_status, items_ok, items_pending, items_apply): what a step sets
#   up, listed once for its status, its confirm_sudo_changes list, and its fixes
# - STEP_OS: the one OS a step supports; the default main and run_steps skip it on the other
# - STEP_NEEDS: the steps a step needs; run_steps skips it when one of them failed earlier
# - the status format: status_item prints an item, and status_parse_line and status_summary_line
#   read a report back, for run_steps and ubuntu/health-alert.sh
# shellcheck shell=bash

# A cd to a relative dir would search an exported CDPATH and print the dir it found, so every
# script that sources this file, and the ones it runs, ignore it
unset CDPATH
DOTFILES_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOTFILES_DIR
# The script that sourced this file, which names a step in step_args's usage line. Made absolute
# now, since a test that loads the step cd's to its sandbox after.
case "${BASH_SOURCE[1]:-}" in
    /*) _SOURCED_BY="${BASH_SOURCE[1]}" ;;
    *) _SOURCED_BY="$PWD/${BASH_SOURCE[1]:-}" ;;
esac

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
# the lists lock, timeout or not, so use apt_get_update for it. LC_ALL=C keeps its messages in
# English for apt_lists_locked, since sudo keeps the caller's locale.
# e.g. apt_get install -y ufw
apt_get() {
    sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"
}

# Tries of apt_get_update, and the seconds between them: about as long as apt_get waits
APT_UPDATE_TRIES=20
APT_UPDATE_RETRY_DELAY=15

# Succeeds when apt-get's output on stdin says another update holds the lists lock. Other errors
# name the lock too, such as "Could not open lock file ... Permission denied", and aren't worth a
# retry.
apt_lists_locked() {
    grep -E '/var/lib/apt/lists/lock' | grep -qE 'Could not get lock|is held by|Unable to acquire'
}

# apt_get update with the arguments given, tried again while another update, such as
# apt-daily's after boot, holds the lists lock. Any other failure returns at once. The notice of
# each wait goes to stderr, so a caller that captures apt-get's output, as add_apt_repo does,
# still shows it.
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

# Succeeds when a file reads exactly the content. For the root-owned files steps write, which
# anyone can read.
file_is() {
    [ "$(cat "$1" 2>/dev/null)" == "$2" ]
}

# List the system changes a step still needs, and ask once before making them with sudo.
# Returns nonzero when confirm declines.
confirm_sudo_changes() {
    echo "  These need sudo:"
    printf '    - %s\n' "$@"
    confirm "  Apply them?" && return 0
    if is_interactive; then
        echo "  Left unchanged."
    else
        echo "  Left unchanged. Run this step from a terminal to apply them."
    fi
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

# Warn when Ubuntu's CPU isn't x86_64, the one setup is tested on. Setup carries on, and a package
# with no build for the CPU fails its step.
warn_untested_platform() {
    local arch
    is_macos && return 0
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
# The same for the runtimes mise installs, such as Node.js
MISE_SHIMS="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
if [ -d "$MISE_SHIMS" ] && [[ ":$PATH:" != *":$MISE_SHIMS:"* ]]; then
    export PATH="$MISE_SHIMS:$PATH"
fi

# Homebrew asks before installing anything with dependencies. The steps install only what they
# list, so don't ask for each one, and don't print tips about Homebrew's environment variables.
export HOMEBREW_NO_ASK=1
export HOMEBREW_NO_ENV_HINTS=1

# has_arg <flag> [arg...]: succeeds when <flag> is among the arguments
# e.g. has_arg --quick "$@"
has_arg() {
    local flag="$1" arg
    shift
    for arg in "$@"; do
        [ "$arg" != "$flag" ] || return 0
    done
    return 1
}

# Succeeds when --status is among the arguments. A step's main gets them all, so it reports
# wherever the flag is.
# e.g. if status_requested "$@"; then status; return $?; fi
status_requested() { has_arg --status "$@"; }

# Succeeds when a status report runs under --quick, which skips its slowest checks
# e.g. if status_quick; then status_item unverified "...: skipped by --quick"; fi
status_quick() { [ "${DOTFILES_STATUS_QUICK:-}" == 1 ]; }

# check_args <usage function> <words|no-words> [arg...]: check a step's or runner's arguments. -h
# or --help prints the usage and exits 0. Any flag but these exits 2. With words, each other
# argument goes in ARG_WORDS, in order; with no-words, one exits 2. --quick without --status exits
# 2 too, since it would otherwise run the steps instead of reporting. What the flags set is
# exported, so the steps a runner starts get it too.
# - --status: a status report changes nothing, and that includes Homebrew's own update.
# - --quick: a status report skips its slowest checks (status_quick).
# - --backup or --no-backup answers every backup question yes or no (maybe_backup).
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
            --quick) export DOTFILES_STATUS_QUICK=1 ;;
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
    if ! status_requested "$@" && has_arg --quick "$@"; then
        echo "--quick only works with --status" >&2
        "$usage_fn" >&2
        exit 2
    fi
}

# Check a step's arguments with check_args. Steps take no words, so a typo such as --stauts, or
# status without its dashes, exits 2 instead of running the step.
# e.g. step_args "$@"
step_args() {
    local step_usage
    # The step is the script that sourced this file, whether it runs directly or a test loaded it
    step_usage="Usage: bash $(_repo_path "$_SOURCED_BY") [--status [--quick]] [--backup | --no-backup]"
    check_args _step_usage no-words "$@"
}

# step_args's usage function, which reads its step_usage
_step_usage() { echo "$step_usage"; }

# STEP_OS: a step that only one OS supports sets STEP_OS=macos or STEP_OS=ubuntu on a line of its
# own near its top, before its functions. On the other OS the default main skips it, and so does
# run_steps, which reads the line without sourcing the step: a run prints "<step>: skipped, macOS
# only", and --status prints one skipped item. Its status and apply then need no OS check of their
# own. MACOS_STEPS and UBUNTU_STEPS still decide which steps a runner runs by default. A step with
# its own main calls step_os_skip itself.
# e.g. STEP_OS=ubuntu

# step_os_skip <step> <step os> [--status]: when <step os> is set and isn't this OS, print the
# skip, as a skipped status item under --status, and succeed. Returns 1 when the step runs here,
# and 2, saying why, when <step os> is neither macos nor ubuntu.
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

# STEP_NEEDS: the steps whose commands a step needs, on a line of its own near its top, after any
# STEP_OS line: the step that installs each command its require_cmd calls check for, which for
# nearly every command is homebrew. When a step it needs failed earlier in the same run, run_steps
# skips it without starting it, printing "<step>: skipped, <needed> failed", and counts it as
# failed, so the re-run hint names it. A needed step that isn't part of the run doesn't gate, and
# neither does a --status report. run_steps reads the line with sed, so it must be a literal list.
# Without sourcing, shellcheck can't see the read, hence the directive.
# e.g. # shellcheck disable=SC2034 # run_steps reads it
#      STEP_NEEDS="homebrew runtimes"

# _failed_need <script> [failed step...]: print the first step the script's STEP_NEEDS names that
# is among the failed steps, and succeed; fail when there's none
_failed_need() {
    local script="$1" need
    shift
    [ $# -gt 0 ] || return 1
    for need in $(step_header_value "$script" STEP_NEEDS); do
        if has_arg "$need" "$@"; then
            echo "$need"
            return 0
        fi
    done
    return 1
}

# step_header_value <script> <var>: print the value a step's script gives <var> on a line of its
# own, as <var>=value or <var>="value", without sourcing it, or nothing. The first such line wins.
# e.g. step_header_value "$DOTFILES_DIR/docker/install.sh" STEP_OS
step_header_value() {
    sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1" 2>/dev/null | head -n 1
}

# Print a step's header line: the first comment line after the shebang, other than a shellcheck
# directive, which says in one sentence what the step does. The runners' --help lists it.
# e.g. step_header_line "$DOTFILES_DIR/docker/install.sh"
step_header_line() {
    awk 'NR > 1 && /^# / && !/^# shellcheck/ { sub(/^# /, ""); print; exit }' "$1"
}

# Print the name of the step a script is: its directory's for an install.sh, such as docker, and
# otherwise its own without .sh, such as manual-steps
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

# The default main of a step: step_args, the STEP_OS skip, then status or apply. Defined only
# while no main is, so a test that loads a step, then lib/common.sh again to bring back a function
# it replaced, keeps the step's own main.
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
            return $?
        fi
        apply
    }
fi

# copy_step <message> <files function>: the apply of a step that only copies configs
# e.g. apply() { copy_step "Copying EditorConfig..." editorconfig_files; }
copy_step() {
    echo "$1"
    "$2" copy_file
}

# copy_status <files function>: the status of a step that only copies configs
# e.g. status() { copy_status editorconfig_files; }
copy_status() {
    "$1" status_file
    status_result
}

# Print a script's path relative to the repo, as a usage line names it
_repo_path() {
    local path
    path="$(cd -- "$(dirname "$1")" && pwd)/${1##*/}"
    echo "${path#"$DOTFILES_DIR"/}"
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
# such as font-monaspace, jq, which steps use to edit JSON settings even if Homebrew breaks, and
# gpg, which checks third-party apt keys' fingerprints. The homebrew step installs them with apt.
# They're listed here so missing_cmd_hint can say so.
UBUNTU_COMMANDS=(cc make curl file git ps zsh lsof col unzip jq gpg)

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

# Copy a file, creating the destination directory. Setup owns the files it copies: one that
# matches, executable bit included, is left alone, and one that differs is replaced, with no
# question or backup, since the repo holds the config. A new file gets 644, or 755 when the source
# is executable, the two modes the repo holds. An existing one keeps its mode, plus the executable
# bits an executable source needs. Each command is checked, since a caller may run this under ||
# or if, where set -e is off. Sets COPIED to true once the file is copied, so a caller that resets
# it can tell whether anything changed.
# e.g. copy_file "$DOTFILES_DIR/vim/vimrc" "$HOME/.vimrc"
copy_file() {
    local src="$1" dest="$2" new_mode=644 exec=""
    if [ -e "$dest" ] && cmp -s "$src" "$dest" && { [ ! -x "$src" ] || [ -x "$dest" ]; }; then
        echo "  $dest is already up to date"
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || return 1
    if [ -x "$src" ]; then
        new_mode=755
        exec=x
    fi
    replace_file "$src" "$dest" "$new_mode" "$exec" || {
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

# Print where backup_file backs a file up: <file>.bak, unless that holds something else, then
# <file>.bak.<timestamp>, adding -2, -3, ... until the name is free or holds the same content
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
# file that differs: it picks backup_path's name instead, so no older backup is overwritten. Fails
# when the copy does; the caller must then leave the file as it is.
backup_file() {
    local file="$1" bak="${2:-}"
    if [ -z "$bak" ] || { [ -e "$bak" ] && ! cmp -s "$file" "$bak"; }; then
        bak="$(backup_path "$file")"
    fi
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

# maybe_backup <file>
# Before editing an existing file, ask whether to back it up, unless <file>.bak already matches
# it. The backup goes where backup_file puts it, so an older, different .bak is kept. --backup or
# --no-backup (DOTFILES_BACKUP) answers for you; otherwise confirm asks, which says no without a
# terminal unless DOTFILES_ASSUME_YES=1. Fails when the backup does; the caller must then leave
# the file as it is.
# e.g. maybe_backup "$CODEX_CONFIG"
maybe_backup() {
    local file="$1" bak
    [ -f "$file" ] || return 0
    cmp -s "$file" "$file.bak" && return 0
    bak="$(backup_path "$file")"
    case "${DOTFILES_BACKUP:-}" in
        no) return 0 ;;
        yes) ;;
        *) confirm "  Back up $file to $bak?" || return 0 ;;
    esac
    backup_file "$file" "$bak"
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

# Print a string with every character an extended regex treats as special escaped, so pgrep or
# grep -E matches it literally
# e.g. pgrep -ax "$(regex_escape "$app")"
regex_escape() {
    # shellcheck disable=SC2016 # a sed pattern, not an expansion
    printf '%s' "$1" | sed 's/[][\.*^$()+?{}|]/\\&/g'
}

# wait_until_quit <pgrep option>... <pattern>: wait up to 10 seconds for no process to match, and
# fail when one still does
# e.g. wait_until_quit -x "Stream Deck"
wait_until_quit() {
    for _ in $(seq 1 20); do
        pgrep "$@" &>/dev/null || return 0
        sleep 0.5
    done
    return 1
}

# Quit a running app (after asking). Returns non-zero if it is still running.
ensure_app_quit() {
    local app="$1" pattern
    # On macOS, -a counts this script's ancestors too; procps's -a only lists full command lines,
    # which the redirect hides.
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

# Succeeds when a tool's home, from its environment variable, is unset or names the default
# directory, however it's spelled. The AI tool steps only write to the default (see
# ai_tools/README.md → Maintenance).
# e.g. tool_home_is "${CODEX_HOME:-}" "$HOME/.codex"
tool_home_is() {
    local home default
    [ -n "$1" ] || return 0
    home="$(cd -P "$1" 2>/dev/null && pwd)" || home="${1%/}"
    default="$(cd -P "$2" 2>/dev/null && pwd)" || default="${2%/}"
    [ "$home" == "$default" ]
}

# Succeeds when a jq expression wouldn't change a JSON file, i.e. its settings are already there.
# The file must hold one value: jq -e takes its status from the last of several, so a file whose
# last value had the settings would pass. The newline ends a comment on the expression's last
# line, which would swallow the comparison.
json_applied() {
    [ -s "$1" ] && jq -s -e "length == 1 and (.[0] | ($2"$'\n'") == .)" "$1" &>/dev/null
}

# Print a file's permission bits in octal, e.g. 644, following a symlink to its target, whose mode
# is the one that counts. It asks stat which form it takes rather than using is_macos, which tests
# override: GNU stat (Ubuntu, or coreutils on macOS) takes -c, and macOS's own takes -f.
file_mode() {
    if stat -c %a / &>/dev/null; then
        stat -L -c %a "$1"
    else
        /usr/bin/stat -L -f %Lp "$1"
    fi
}

# replace_file <src> <dest> <new-mode> [x]
# Replace a file with a copy of another. The copy goes to a new file in the same directory, which
# is then moved into place, so a failed or partial write leaves the old file whole, and a script
# running from the old file reads on unchanged. A symlink's target is replaced the same way, so
# the link stays. A dangling symlink fails, as json_merge does. The file keeps its mode, plus
# executable bits where it has read bits with x; a new file gets <new-mode>. A file made
# read-only fails with 2 and stays as it is, as cp would leave it, though its directory would let
# a rename replace it. Prints nothing.
replace_file() {
    local src="$1" dest="$2" mode="$3" tmp target
    if [ -L "$dest" ]; then
        # macOS's readlink and GNU's both take -f, and follow every link in the chain. On a dangling
        # link macOS's prints the path and fails, and GNU's succeeds, so check the target exists.
        if ! target="$(readlink -f -- "$dest" 2>/dev/null)" || [ -z "$target" ] || [ ! -e "$target" ]; then
            return 1
        fi
        dest="$target"
    fi
    # mv would move the copy into a directory
    [ ! -d "$dest" ] || return 1
    [ ! -e "$dest" ] || [ -w "$dest" ] || return 2
    if [ -e "$dest" ]; then
        mode="$(file_mode "$dest")" || return 1
        [ -z "${4:-}" ] || mode="$(printf '%o' $((0$mode | ((0$mode & 0444) >> 2))))"
    fi
    tmp="$(mktemp "$(dirname "$dest")/.${dest##*/}.XXXXXX" 2>/dev/null)" || return 1
    # cp onto the existing temp file keeps mktemp's 600 until chmod
    if cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Replace a file's contents with a temp file's, as replace_file does, then remove the temp file. A
# new file gets the mode umask gives it. Fails, keeping the temp file and saying where it is, when
# the write does or the file is read-only.
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

# Merge a jq expression into a JSON file, creating the file if needed. A file the expression
# doesn't change is left alone, unformatted and not backed up.
json_merge() {
    local file="$1" filter="$2" tmp input="" values
    require_cmd jq || return 1
    ! json_applied "$file" "$filter" || return 0
    # A missing or blank file starts as {}. One that can't be read, such as a dangling symlink,
    # fails rather than start from {} and lose what it holds. Nothing is backed up or written until
    # jq yields exactly one JSON value.
    if [ -e "$file" ] || [ -L "$file" ]; then
        if ! input="$(cat -- "$file")"; then
            echo "  Couldn't read $file, so it was left as it is." >&2
            return 1
        fi
    fi
    [[ "$input" =~ [^[:space:]] ]] || input='{}'
    # jq's own error says where invalid JSON goes wrong
    if ! values="$(printf '%s\n' "$input" | jq -s length)"; then
        echo "  $file isn't valid JSON, so it was left as it is." >&2
        return 1
    elif [ "$values" != 1 ]; then
        echo "  $file holds $values JSON values, not one, so it was left as it is." >&2
        return 1
    fi
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

# Set once status_item prints an item that needs attention
STATUS_NEEDS_ATTENTION=false

# The status format, defined here once. A --status report is lines a person reads, which
# run_steps and ubuntu/health-alert.sh also parse, through status_parse_line and
# status_summary_line, so a change to how items look changes all three together:
# - an item is two spaces, its state padded to STATUS_STATE_WIDTH, a space, and its text
# - run_steps puts a "<step>:" header before each step's items, and ends a run with the summary
#   lines "Needs attention: ..." and "Failed steps: ..."
# States:
#   ok          set up
#   missing     not set up; running the step (or the manual step it names) sets it up
#   skipped     doesn't apply here, such as on the other OS or in a VM; say why
#   unverified  looks set up, but the rest wasn't checked, e.g. without sudo or under --quick; say
#               why. Unlike missing and unknown, it doesn't need attention.
#   unknown     can't be checked, e.g. because a tool is missing or a download failed; say why
#   info        a value to know rather than something setup sets up, such as whether FileVault is
#               on, or that such a check couldn't run; it doesn't need attention
STATUS_STATES="ok missing skipped unverified unknown info"
STATUS_STATE_WIDTH=10
STATUS_SUMMARY_ATTENTION="Needs attention"
STATUS_SUMMARY_FAILED="Failed steps"

# Print one item of a step's --status report
# e.g. status_item missing "~/.zshrc sources main.zsh"
status_item() {
    printf "  %-${STATUS_STATE_WIDTH}s %s\n" "$1" "$2"
    ! status_state_needs_attention "$1" || STATUS_NEEDS_ATTENTION=true
}

# Succeeds for a state that needs attention: missing or unknown
status_state_needs_attention() {
    case "$1" in
        missing | unknown) return 0 ;;
    esac
    return 1
}

# status_parse_line <line>: succeed when the line is a status item, setting STATUS_LINE_STATE and
# STATUS_LINE_TEXT to its state and text. Other lines, such as a header, a summary, or a step's
# own output, fail.
status_parse_line() {
    local line="$1" state padded
    state="${line:2:$STATUS_STATE_WIDTH}"
    state="${state%% *}"
    case " $STATUS_STATES " in
        *" $state "*) ;;
        *) return 1 ;;
    esac
    printf -v padded "  %-${STATUS_STATE_WIDTH}s " "$state"
    [ "${line:0:${#padded}}" == "$padded" ] || return 1
    STATUS_LINE_STATE="$state"
    # shellcheck disable=SC2034 # callers read it
    STATUS_LINE_TEXT="${line:${#padded}}"
}

# Succeeds when a line is one of run_steps' summary lines
status_summary_line() {
    case "$1" in
        "$STATUS_SUMMARY_ATTENTION: "* | "$STATUS_SUMMARY_FAILED: "*) return 0 ;;
    esac
    return 1
}

# _status_relay <header>: run_steps' classifier for one step's report. Copies stdin to stdout as
# each line comes, after <header> when there's a first line, and succeeds when an item needs
# attention: a report that set -e cut short at a command that exited 3, such as jq on a filter
# that doesn't compile, exits 3 too, so the exit code alone can't tell.
_status_relay() {
    local line attention=1 first=true
    while IFS= read -r line || [ -n "$line" ]; do
        if "$first"; then
            printf '%s\n' "$1"
            first=false
        fi
        printf '%s\n' "$line"
        if status_parse_line "$line" && status_state_needs_attention "$STATUS_LINE_STATE"; then
            attention=0
        fi
    done
    return "$attention"
}

# Succeeds when sudo credentials are cached, so sudo -n runs without asking for a password. A
# status function may read root-only settings with sudo -n when it does, and never asks.
sudo_cached() {
    sudo -n true 2> /dev/null
}

# sudo_cached, as a step found it once and saved it in SUDO_CACHED_CACHE (yes or no), so the
# answer stays the same through one status run. Unset, it asks sudo each time.
sudo_ready() {
    if [ -n "${SUDO_CACHED_CACHE:-}" ]; then
        [ "$SUDO_CACHED_CACHE" == yes ]
        return
    fi
    sudo_cached
}

# The oldest yq the codex step's config edit and scripts/check-tool-versions.sh take: yq -o toml's
# encoder arrived in 4.52.1 and was fixed up to 4.54.1
# shellcheck disable=SC2034 # they read it
YQ_MIN_VERSION=4.54.1

# version_at_least <version> <minimum>: compare dot-separated numbers, a missing part counting as 0
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

# Run an external command, stopping it after <seconds> with exit status 124, as timeout(1) does,
# for a status check that can hang, such as smartctl on a failing disk. macOS has no timeout(1), so
# there perl's alarm stops only the command, not what it started; its macOS callers (fdesetup,
# socketfilterfw, df) start nothing. Without perl either, the command runs unbounded.
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

# Items: a step lists each simple thing it sets up once, with item, so its status, its
# confirm_sudo_changes list, and its fixes can't drift apart.
#   items_reset
#   item [--sudo] [--hint <text>] <status text> <pending text> <check-fn> <fix-fn>
# The check succeeds when the thing is set up, and the fix sets it up. The status text describes
# the state the check looks for, as status_check's does; the pending text describes the change, as
# confirm_sudo_changes lists it. --sudo marks a fix that needs sudo. --hint adds what to do to a
# missing status item, such as a command the step won't run itself.
# Declare a step's items in one function that starts with items_reset, so a test that loads two
# steps gets each step's own, and call it from both status and apply. Items are added at run time,
# so their texts can name paths a test points elsewhere. An item that branches, such as one with
# two pending texts or a status that can be unverified, stays custom code in its place.
# The drivers take the check functions of the items to drive, every item when given none, and
# drive them in the order they were declared:
#   items_status [check-fn...]   status_item ok "<status text>", or missing "<status text>[; <hint>]"
#   items_pending [check-fn...]  append the pending text of each failing --sudo item to the caller's
#                                pending array, for confirm_sudo_changes
#   items_ok [check-fn...]       succeed when every item's check passes, printing nothing
#   items_apply [--no-sudo] [check-fn...]
#                                run the fix of each item whose check still fails; --no-sudo skips
#                                the --sudo items, for when confirm_sudo_changes was declined. Every
#                                fix runs whether or not one before it failed; returns 1 when any did.
# e.g. items_reset
#      item --sudo "Linger, so user services start at boot" \
#          "Start your user services at boot: loginctl enable-linger" lingering enable_linger
ITEM_STATUS=()
ITEM_PENDING=()
ITEM_CHECK=()
ITEM_FIX=()
ITEM_SUDO=()
ITEM_HINT=()

items_reset() {
    ITEM_STATUS=()
    ITEM_PENDING=()
    ITEM_CHECK=()
    ITEM_FIX=()
    ITEM_SUDO=()
    ITEM_HINT=()
}

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
        echo "item: expected <status text> <pending text> <check-fn> <fix-fn>, got $# arguments" >&2
        return 2
    fi
    ITEM_STATUS+=("$1")
    ITEM_PENDING+=("$2")
    ITEM_CHECK+=("$3")
    ITEM_FIX+=("$4")
    ITEM_SUDO+=("$sudo")
    ITEM_HINT+=("$hint")
}

# shellcheck disable=SC2120 # with no check functions, it drives every item
items_status() {
    local i=0
    while [ "$i" -lt ${#ITEM_CHECK[@]} ]; do
        if _item_wanted "$i" "$@"; then
            if "${ITEM_CHECK[i]}"; then
                status_item ok "${ITEM_STATUS[i]}"
            else
                status_item missing "${ITEM_STATUS[i]}${ITEM_HINT[i]:+; ${ITEM_HINT[i]}}"
            fi
        fi
        i=$((i + 1))
    done
}

# shellcheck disable=SC2120 # with no check functions, it checks every item
items_ok() {
    local i=0
    while [ "$i" -lt ${#ITEM_CHECK[@]} ]; do
        if _item_wanted "$i" "$@" && ! "${ITEM_CHECK[i]}"; then
            return 1
        fi
        i=$((i + 1))
    done
}

# e.g. local pending=(); items_pending sleep_masked sleep_conf_written
# shellcheck disable=SC2120 # with no check functions, it lists every sudo item
items_pending() {
    local i=0
    while [ "$i" -lt ${#ITEM_CHECK[@]} ]; do
        if "${ITEM_SUDO[i]}" && _item_wanted "$i" "$@" && ! "${ITEM_CHECK[i]}"; then
            pending+=("${ITEM_PENDING[i]}")
        fi
        i=$((i + 1))
    done
}

# shellcheck disable=SC2120 # with no check functions, it drives every item
items_apply() {
    local i=0 result=0 sudo=true
    if [ "${1:-}" == --no-sudo ]; then
        sudo=false
        shift
    fi
    while [ "$i" -lt ${#ITEM_CHECK[@]} ]; do
        if { "$sudo" || ! "${ITEM_SUDO[i]}"; } && _item_wanted "$i" "$@" && ! "${ITEM_CHECK[i]}"; then
            "${ITEM_FIX[i]}" || result=1
        fi
        i=$((i + 1))
    done
    return "$result"
}

# _item_wanted <index> [check-fn...]: succeeds when the item is among the checks named, or none is
_item_wanted() {
    local check="${ITEM_CHECK[$1]}"
    shift
    [ $# -eq 0 ] || has_arg "$check" "$@"
}

# Print an item for whether a file copy_file installs matches its source in the repo, and is
# executable when the source is. A file that differs is missing, since the step's next run
# replaces it.
# e.g. status_file "$DOTFILES_DIR/zed/keymap.json" ~/.config/zed/keymap.json
status_file() {
    local src="$1" dest="$2" shown="$2"
    # shellcheck disable=SC2088 # shown, not expanded
    [[ "$dest" == "$HOME/"* ]] && shown="~/${dest#"$HOME"/}"
    if cmp -s "$src" "$dest"; then
        # A command the step makes executable, such as git-wt, can't run without the bit
        if [ -x "$src" ] && [ ! -x "$dest" ]; then
            status_item missing "$shown isn't executable"
        else
            status_item ok "$shown"
        fi
    elif [ -e "$dest" ]; then
        status_item missing "$shown differs from the repo's ${src#"$DOTFILES_DIR"/}"
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

# A step's status function returns this: 3 when any item needs attention, otherwise 0
status_result() {
    "$STATUS_NEEDS_ATTENTION" && return 3
    return 0
}

# Print the script of a step in the caller's MACOS_STEPS or UBUNTU_STEPS: $STEPS_DIR/manual-steps.sh
# for manual-steps, otherwise $STEPS_DIR/<step>/install.sh. Fails for any other name, such as
# "git lazygit", which the list check alone would take. Either OS's steps resolve, so a step named
# on the other OS reaches its own skip message.
step_script() {
    case "$1" in
        '' | *[[:space:]/]*) return 1 ;;
    esac
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

# runner_main <name> <quick> [arg...]
# The runners' shared body: pick STEPS for this OS, read the arguments, flags and step names in
# any order, then run the steps, or with --status their reports, under headers naming <name>.
# <quick> ends the usage's --status sentence, saying what --quick skips. The caller sets
# MACOS_STEPS, UBUNTU_STEPS, and STEPS_DIR. Sets RUNNER_STEPS to the steps named. Exits with the
# --status result (3 when something needs attention, 1 when a step failed) and when a step fails;
# returns after a successful run. An interrupted run dies of the signal that stopped it.
runner_main() {
    local name="$1" quick="$2" script status=0
    shift 2
    script="$(_repo_path "${BASH_SOURCE[1]}")"
    if is_macos; then
        STEPS=("${MACOS_STEPS[@]}")
    else
        STEPS=("${UBUNTU_STEPS[@]}")
    fi
    check_args _runner_usage words "$@"
    RUNNER_STEPS=(${ARG_WORDS[@]+"${ARG_WORDS[@]}"})
    if status_requested "$@"; then
        echo "=== $name status ==="
        run_steps --status ${RUNNER_STEPS[@]+"${RUNNER_STEPS[@]}"} || status=$?
        reraise_interrupt "$status"
        exit "$status"
    fi
    echo "=== $name setup ==="
    run_steps "" ${RUNNER_STEPS[@]+"${RUNNER_STEPS[@]}"} || status=$?
    reraise_interrupt "$status"
    [ "$status" -eq 0 ] || exit "$status"
    echo ""
    echo "=== $name setup complete! ==="
}

# runner_main's usage function, which reads its script and quick
_runner_usage() {
    local step
    echo "Usage: bash $script [--status [--quick]] [--backup | --no-backup] [step...]"
    echo "Steps, run in this order by default: ${STEPS[*]}"
    for step in "${STEPS[@]}"; do
        printf '  %-15s %s\n' "$step" "$(step_header_line "$(step_script "$step")")"
    done
    echo "--status reports what each step has set up, changing nothing. It exits 3 for missing or"
    echo "unknown items. $quick"
    echo "A config file that differs from the repo's is replaced. Settings merged into files other"
    echo "tools also edit ask whether to back up the file first. --backup or --no-backup answers"
    echo "every backup question yes or no."
    echo "Flags may come before or after the step names."
}

# Succeeds when exit status $1 means SIGHUP, SIGINT (Ctrl-C), or SIGTERM stopped the command, so
# the caller stops too. brew catches SIGINT and exits 130, so bash doesn't see the signal itself
# and would carry on. Other codes above 128, such as 141 from SIGPIPE or 255 from ssh, are
# failures like any other. run_steps also traps the signals, since a step that runs brew under
# `|| result=1` turns its 130 into 1.
interrupted_status() {
    [ "$1" -eq 129 ] || [ "$1" -eq 130 ] || [ "$1" -eq 143 ]
}

# Kill this shell with the signal an interrupted status stands for, with the signal's default
# action, so whatever ran it stops too: bash carries on after a command that exited 130, but not
# after one SIGINT killed. Returns for any other status. run_steps returns the status instead,
# since $$ is the top shell's PID even in a subshell.
reraise_interrupt() {
    local sig
    case "$1" in
        129) sig=HUP ;;
        130) sig=INT ;;
        143) sig=TERM ;;
        *) return 0 ;;
    esac
    trap - INT TERM HUP
    kill -s "$sig" $$
    exit "$1"
}

# run_steps <mode> [step...]
# An empty mode runs the named steps, or every step in $STEPS, in order, each in its own process. A failing step
# doesn't stop the rest; the failures are listed at the end with the command that re-runs them,
# and the run fails. With mode --status, run each step's report instead, under a header with its
# name. Steps with an item needing attention are listed too, and the run returns 3 (1 when a step
# also failed); one with such an item that exits 0 is listed too. A report that exits 3 without
# such an item failed.
run_steps() {
    local mode="$1" step script status codes skipped blocker interrupted="" failed=() attention=()
    shift
    require_supported_os || return 1
    # step_script takes either OS's steps, so the error lists both
    for step in "$@"; do
        step_script "$step" > /dev/null || {
            echo "Unknown step: $step. Steps on macOS: ${MACOS_STEPS[*]}. On Ubuntu: ${UBUNTU_STEPS[*]}" >&2
            return 1
        }
    done
    warn_untested_platform
    # shellcheck disable=SC2154 # STEPS is set by the caller
    [ $# -gt 0 ] || set -- "${STEPS[@]}"
    # Ctrl-C reaches the whole process group, but bash takes a step that exits normally to have
    # handled it, and would carry on. These run once the step exits.
    trap 'interrupted=130' INT
    trap 'interrupted=143' TERM
    trap 'interrupted=129' HUP
    for step in "$@"; do
        script="$(step_script "$step")"
        status=0
        # A step for the other OS is skipped here, without starting it. Its own main reports a
        # STEP_OS that's neither.
        if [ -n "$mode" ] && skipped="$(step_os_skip "$step" "$(step_header_value "$script" STEP_OS)" --status 2>/dev/null)"; then
            printf '%s:\n%s\n' "$step" "$skipped"
            continue
        elif [ -z "$mode" ] && step_os_skip "$step" "$(step_header_value "$script" STEP_OS)" 2>/dev/null; then
            continue
        fi
        if [ -z "$mode" ] && blocker="$(_failed_need "$script" ${failed[@]+"${failed[@]}"})"; then
            echo "$step: skipped, $blocker failed" >&2
            failed+=("$step")
            continue
        fi
        if [ -n "$mode" ]; then
            # The header goes before the step's first line, so a step that reports nothing (such
            # as manual-steps) prints nothing. -e is off in the group, so PIPESTATUS is read.
            {
                "$BASH" "$script" --status | _status_relay "$step:"
                codes="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
            } || true
            status="${codes% *}"
            if [ "${codes#* }" -eq 0 ]; then
                # A report that forgot status_result exits 0 with an item needing attention
                [ "$status" -ne 0 ] || status=3
            elif [ "$status" -eq 3 ]; then
                status=1
            fi
        else
            "$BASH" "$script" || status=$?
        fi
        [ -z "$interrupted" ] || status="$interrupted"
        if interrupted_status "$status"; then
            echo "  The $step step was interrupted; stopping." >&2
            trap - INT TERM HUP
            return "$status"
        elif [ -n "$mode" ] && [ "$status" -eq 3 ]; then
            attention+=("$step")
        elif [ "$status" -ne 0 ]; then
            echo "  The $step step failed." >&2
            failed+=("$step")
        fi
    done
    trap - INT TERM HUP
    if [ ${#attention[@]} -gt 0 ]; then
        echo ""
        echo "$STATUS_SUMMARY_ATTENTION: ${attention[*]}. Run: bash $0 ${attention[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        echo "" >&2
        echo "$STATUS_SUMMARY_FAILED: ${failed[*]}" >&2
        echo "Fix the errors above, then re-run them with: bash $0 ${mode:+$mode }${failed[*]}" >&2
        return 1
    fi
    [ ${#attention[@]} -eq 0 ] || return 3
}
