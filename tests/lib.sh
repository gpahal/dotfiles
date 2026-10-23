# Test helpers. Sourcing this runs set -euo pipefail and setup_sandbox, which makes $SANDBOX
# (exported, for stubs to read) and points HOME and the stubs into it; source any fixture after it.
# A test then runs steps or load_script, checks with assert_*, and ends with test_done. Stub every
# SENTINELS command it reaches; hide makes one missing. A test with its own EXIT trap ends it with
# _sandbox_exit, as setup_sandbox's comment shows.
# run and assert_exit empty $STUB_LOG first, so the log holds one run's commands; to check two
# runs', save the log between them.
# Change a loaded function only with replace_fn, wrap_fn, as_os macos|ubuntu, or answer
# yes|no|stdin.
# tests/run.sh covers skips, timeouts, the os mark, timing, and sharding.
# Reuse before writing your own: stub_at, stub_sudo_exec, stub_sudo_cacheable, stub_uname,
# stub_dpkg_arch, stub_apt_packages, stub_apt_config, stub_gpg_fpr, stub_http_status, stub_fetch,
# stub_gsettings, stub_gnome_session, stub_systemctl_units, sandbox_paths, fake_step,
# fake_github_remotes, pam_sandbox, user_shortcut, git_commit, in_terminal, jq_edit, diag,
# assert_sudo_noninteractive, assert_read_only, assert_idempotent, snapshot and assert_unchanged,
# as_unwritable, wait_for, and process_exited. A test sets df's output in $SANDBOX/df-table.
# tests/ubuntu-sandbox.sh points the ubuntu step's system paths into the sandbox, and
# tests/ubuntu-step-fixture.sh, which sources it, stubs an Ubuntu machine for that step.
# shellcheck shell=bash

set -euo pipefail

TESTS_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
TEST_FAILURES=0
TEST_SKIPPED=false
TEST_DONE=false

# shellcheck source=sentinels.sh
source "$TESTS_DIR/sentinels.sh"

# Sourcing this file runs it. It sets the EXIT trap; a test that sets its own ends it with
# _sandbox_exit, keeping $?:
# trap 'status=$?; set +e; <cleanup>; (exit "$status"); _sandbox_exit' EXIT
setup_sandbox() {
    local var
    # /tmp keeps tmux's socket path under macOS's limit; -P makes printed paths match $HOME
    SANDBOX="$(cd -P "$(mktemp -d "${TEST_SANDBOX_PARENT:-/tmp}/dotfiles-test.XXXXXX")" && pwd)"
    # Stubs read it at run time
    export SANDBOX
    trap _sandbox_exit EXIT
    # GIT_* from a hook or worktree would point git at the real repo or add config
    for var in $(compgen -e | grep -E '^(XDG_|DOTFILES_|GIT_)' || true); do
        unset "$var"
    done
    unset CDPATH BASH_ENV TMUX TMUX_PANE ZDOTDIR CODEX_HOME CLAUDE_CONFIG_DIR SSH_AUTH_SOCK \
        SSH_USER_AUTH SSH_CONNECTION SSH_CLIENT SSH_TTY MISE_DATA_DIR MISE_CONFIG_DIR \
        MISE_GLOBAL_CONFIG_FILE MISE_STATE_DIR MISE_CACHE_DIR
    # A test that clones rewrites the url to a local repo, as test-tmux-plugins.sh does
    export GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
    # The sandbox has no git identity
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t \
        GIT_COMMITTER_EMAIL=t@example.com
    export HOME="$SANDBOX/home" TMUX_TMPDIR="$SANDBOX/tmux" WORKTREES_DIR="$SANDBOX/worktrees"
    # macOS's mktemp ignores TMPDIR without a template, so a wrapper below adds one
    export TMPDIR="$SANDBOX/tmp"
    # Stops zsh/path.zsh loading the real Homebrew ahead of the stubs
    export HOMEBREW_PREFIX="$SANDBOX/no-homebrew"
    export APT_SOURCES_DIR="$SANDBOX/apt/sources.list.d" OS_RELEASE="$SANDBOX/os-release"
    mkdir -p "$APT_SOURCES_DIR"
    printf '%s\n' ID=ubuntu VERSION_ID='"26.04"' VERSION_CODENAME=resolute UBUNTU_CODENAME=resolute > "$OS_RELEASE"
    export STUB_DIR="$SANDBOX/stubs" STUB_LOG="$SANDBOX/stub.log"
    mkdir -p "$HOME" "$TMUX_TMPDIR" "$WORKTREES_DIR" "$TMPDIR" "$STUB_DIR"
    : > "$STUB_LOG"
    printf '%s\n' '#!/bin/bash' \
        "case \"\$*\" in '' | -d) exec $(command -v mktemp) \"\$@\" \"\$TMPDIR/tmp.XXXXXXXXXX\" ;; esac" \
        "exec $(command -v mktemp) \"\$@\"" > "$STUB_DIR/mktemp"
    chmod +x "$STUB_DIR/mktemp"
    _stubs_first
    # shellcheck disable=SC2086 # a list of names
    _sentinels $SENTINELS
    stub sudo 'exit 1'
    export DOTFILES_PAM_DIR="$SANDBOX/pam.d" DOTFILES_PAM_MODULES_DIR="$SANDBOX/pam-modules" \
        DOTFILES_PAM_LOCAL_MODULES_DIR="$SANDBOX/pam-local-modules"
    # Real free space would sway status reports. A test sets its own in $SANDBOX/df-table, as df
    # prints them: df prints the first line that names the path, else the first line, and fails
    # for a path listed in $SANDBOX/df-fails.
    stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
if [ -e "$SANDBOX/df-table" ]; then
    path="${!#}"
    ! grep -qxF -- "$path" "$SANDBOX/df-fails" 2> /dev/null || { echo "df: $path: No such file or directory" >&2; exit 1; }
    line="$(grep -F " $path" "$SANDBOX/df-table" | head -n 1)"
    [ -n "$line" ] || line="$(head -n 1 "$SANDBOX/df-table")"
    echo "$line"
    exit 0
fi
for path in "$@"; do case "$path" in -*) ;; *) echo "/dev/test 1048576000 104857600 943718400 10% $path" ;; esac; done'
    exec < /dev/null
    # Else a relative path would reach the repo's tests/
    cd "$SANDBOX"
}

_sandbox_exit() {
    local status=$?
    # Catches sentinels run under `|| true`
    if [ -s "$SANDBOX/unstubbed.log" ]; then
        echo "Commands ran that the test didn't stub:" >&2
        _show "$(cat "$SANDBOX/unstubbed.log")"
        TEST_FAILURES=$((TEST_FAILURES + 1))
    fi
    # A tmux server outlives its socket's dir
    _stop_tmux_servers
    case "${SANDBOX:-}" in
        */dotfiles-test.*)
            chmod -R u+w "$SANDBOX" 2>/dev/null || true
            rm -rf "$SANDBOX"
            ;;
    esac
    # bash 3.2 gives the EXIT trap $? 0 when set -u stops a script
    if [ "$status" -eq 0 ] && ! "$TEST_DONE"; then
        echo "The test stopped before its test_done line" >&2
        status=1
    fi
    if [ "$TEST_FAILURES" -gt 0 ]; then
        echo "$TEST_FAILURES check(s) failed" >&2
        [ "$status" -ne 0 ] && [ "$status" -ne 77 ] || status=1
    elif [ "$status" -eq 0 ] && "$TEST_SKIPPED"; then
        status=77
    fi
    exit "$status"
}

# Waits for the panes to exit: a pane's zsh writing ~/.zsh_history would race the sandbox removal
_stop_tmux_servers() {
    local sock pids="" pid i=0 alive
    command -v tmux &>/dev/null || return 0
    for sock in "$TMUX_TMPDIR"/tmux-*/*; do
        [ -S "$sock" ] || continue
        pids="$pids $(tmux -S "$sock" list-panes -a -F '#{pid} #{pane_pid}' 2>/dev/null | tr '\n' ' ' || true)"
        tmux -S "$sock" kill-server &>/dev/null || true
    done
    while [ "$i" -lt 50 ]; do
        alive=false
        for pid in $pids; do
            ! kill -0 "$pid" 2>/dev/null || alive=true
        done
        "$alive" || return 0
        sleep 0.1
        i=$((i + 1))
    done
}

# lib/common.sh prepends Homebrew's and mise's dirs, which would hide the stubs
_stubs_first() {
    local path=":$PATH:"
    path="${path//:$STUB_DIR:/:}"
    path="${path#:}"
    export PATH="$STUB_DIR:${path%:}"
}

# The stub logs "<cmd> <args>" to $STUB_LOG, then runs the body with the args as "$@"
stub() {
    stub_at "$STUB_DIR/$1" "${2:-}"
}

# stub_at <path> [body]: a stub at any path, such as an app's own copy of a command, logged as the
# name it runs by
stub_at() {
    [ -d "${1%/*}" ] || mkdir -p "${1%/*}"
    printf '%s\n' '#!/bin/bash' 'printf '"'%s\\n'"' "${0##*/}${*:+ $*}" >> "$STUB_LOG"' "${2:-}" > "$1"
    chmod +x "$1"
}

# Stub sudo to run its command as you, dropping install's -o and -g, which need root. It refuses
# paths outside the sandbox and /dev, and repo files the command would change. The optional body
# runs first and may rewrite "$@" with set --.
stub_sudo_exec() {
    stub sudo "${1:-}
$(printf 'sandbox=%q repo=%q' "$SANDBOX" "$REPO_DIR")"'
[ "${1:-}" != -n ] || shift
# The command, after any VAR=value words, and which of its files it reads: all, all but the last,
# or none, as install -d makes each dir it is given
cmd=""
for arg in "$@"; do
    case "$arg" in
        *=*) ;;
        *)
            cmd="${arg##*/}"
            break
            ;;
    esac
done
case "$cmd" in
    cat | bash | sh | head | tail | grep | diff | cmp | stat | test | \[) reads=all ;;
    rm | rmdir | mv | chmod | chown | chgrp | touch | tee | truncate | mkdir | unlink | sed) reads=none ;;
    *) reads=all-but-last ;;
esac
case " $* " in *" -d "*) [ "$cmd" != install ] || reads=none ;; esac
if [ "$cmd" == install ]; then
    args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -o | -g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    set -- "${args[@]}"
fi
i=0
for arg in "$@"; do
    i=$((i + 1))
    case "$arg" in
        /dev/* | "$sandbox" | "$sandbox"/* | *=/dev/* | *="$sandbox" | *="$sandbox"/*) ;;
        "$repo"/* | *="$repo"/*)
            case "$reads" in
                all) continue ;;
                all-but-last) [ "$i" -eq $# ] || continue ;;
            esac
            echo "refused: $cmd would change $arg, in the repo" >&2
            exit 1
            ;;
        /* | *=/*)
            echo "refused: $arg is outside the sandbox" >&2
            exit 1
            ;;
    esac
done
exec env "$@"'
}

# stub_sudo_exec where sudo -n works only after `cache_sudo yes`, as after sudo -v. The optional
# body runs next, with -n shifted off.
stub_sudo_cacheable() {
    stub_sudo_exec 'if [ "${1:-}" == -n ]; then
    [ -e "$SANDBOX/sudo-cached" ] || exit 1
    shift
fi
'"${1:-}"
}

# PAM dirs for macos/lib/pam.sh, fresh: a sudo that includes sudo_local and macOS's pam_tid.so.2.
# Sets SUDO_LOCAL, HEADER and TID_LINE, the lines the Touch ID script writes, and makes "root-owned"
# mean owned by you. Call it after load_script.
pam_sandbox() {
    rm -rf "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR" "$DOTFILES_PAM_LOCAL_MODULES_DIR"
    mkdir -p "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR"
    printf '%s\n' "# sudo: auth account password session" "auth       include        sudo_local" \
        "auth       required       pam_opendirectory.so" > "$DOTFILES_PAM_DIR/sudo"
    # OpenPAM finds macOS's .so.2 modules by bare name
    touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
    # shellcheck disable=SC2034 # tests and macos/lib/pam.sh read them
    PAM_ROOT_UID="$(id -u)" SUDO_LOCAL="$DOTFILES_PAM_DIR/sudo_local" \
        HEADER="# sudo_local: local config file which survives system update and is included for sudo" \
        TID_LINE="auth       sufficient     pam_tid.so"
}

cache_sudo() {
    case "$1" in
        yes) touch "$SANDBOX/sudo-cached" ;;
        no) rm -f "$SANDBOX/sudo-cached" ;;
        *) fail "cache_sudo: '$1' isn't yes or no" ;;
    esac
}

# Stub `apt-config shell`; the body prints the config as `apt-config dump` would. Without one,
# periodic package list updates and unattended upgrades are on.
stub_apt_config() {
    local config="${1:-}"
    if [ -z "$config" ]; then
        config='echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"1\";"'
    fi
    stub apt-config "config() {
$config
}
$(
        cat << 'EOF'
[ "$1" == shell ] || exit 100
shift
dump="$(config)"
while [ $# -ge 2 ]; do
    awk -v var="$1" -v key="$2" -v q="'" '
        index($0, key " \"") == 1 { value = substr($0, length(key) + 3); sub(/";$/, "", value); found = 1 }
        END { if (found) print var "=" q value q }' <<< "$dump"
    shift 2
done
EOF
    )"
}

_sentinels() {
    local cmd body
    body="$(printf '#!/bin/bash\nlog=%q\n' "$SANDBOX/unstubbed.log")"'
printf '"'%s\\n'"' "${0##*/}${*:+ $*}" >> "$log"
echo "unstubbed command: ${0##*/}" >&2
exit 127'
    for cmd; do
        printf '%s\n' "$body" > "$STUB_DIR/$cmd"
    done
    [ $# -eq 0 ] || (cd "$STUB_DIR" && chmod +x "$@")
}

# Make commands missing even where installed. Each shell's first hide copies $STUB_DIR, so a
# subshell's hide can't delete the parent's sentinels.
hide() {
    local dir name dirs
    # bash 3.2 has no BASHPID
    if [ "${_HIDE_SHELL-}" != "$BASH_SUBSHELL" ]; then
        _HIDE_SHELL="$BASH_SUBSHELL"
        dir="$(mktemp -d "$SANDBOX/hide.XXXXXX")"
        cp -Rp "$STUB_DIR" "$dir/stubs"
        _HIDE_LINKS="$dir/path"
        mkdir "$_HIDE_LINKS"
        IFS=: read -ra dirs <<< "$PATH"
        for dir in ${dirs[@]+"${dirs[@]}"}; do
            [ "$dir" != "$STUB_DIR" ] && [ -d "$dir" ] || continue
            # ln skips names already linked, as PATH lookup would
            ln -s "$dir"/* "$_HIDE_LINKS"/ 2> /dev/null || true
        done
        STUB_DIR="${_HIDE_LINKS%/path}/stubs"
    fi
    # Also resets a PATH a script changed since the last hide
    export PATH="$STUB_DIR:$_HIDE_LINKS"
    for name in "$@"; do
        rm -f "$_HIDE_LINKS/$name" "$STUB_DIR/$name"
        # Else lib/common.sh adds Homebrew's dirs when it finds no brew
        [ "$name" != brew ] || export DOTFILES_NO_LOAD_BREW=1
    done
}

# skip_rest carries on; the test then exits 77 unless a check failed
skip() {
    echo "SKIP: $1"
    exit 77
}

skip_rest() {
    echo "SKIP: $1"
    TEST_SKIPPED=true
}

# Run in a subshell, so its hides and replaced functions stay there
# shellcheck disable=SC2030,SC2031 # the subshell counts its own failures
subtest() {
    local failed=0
    (
        TEST_FAILURES=0
        "$@"
        exit "$TEST_FAILURES"
    ) || failed=$?
    TEST_FAILURES=$((TEST_FAILURES + failed))
}

# Fails when there's no such function, since the override would then test nothing
replace_fn() {
    declare -F "$1" > /dev/null || fail "replace_fn: no function $1 to replace"
    eval "$1() {
${2:-:}
}"
}

# replace_fn that first saves the function as real_<name>, for the new body to call or restore_fn
# to put back. A function already wrapped keeps its first saved copy.
wrap_fn() {
    if declare -F "$1" > /dev/null && ! declare -F "real_$1" > /dev/null; then
        eval "real_$(declare -f "$1")"
    fi
    replace_fn "$1" "${2:-:}"
}

restore_fn() {
    local def
    def="$(declare -f "real_$1")" || {
        fail "restore_fn: $1 isn't wrapped"
        return 0
    }
    eval "${def#real_}"
    unset -f "real_$1"
}

# A step run as its own process needs stub_uname instead
as_os() {
    case "$1" in
        macos)
            replace_fn is_macos 'return 0'
            replace_fn is_ubuntu 'return 1'
            ;;
        ubuntu)
            replace_fn is_macos 'return 1'
            replace_fn is_ubuntu 'return 0'
            ;;
        *) fail "as_os: '$1' isn't macos or ubuntu" ;;
    esac
}

# answer stdin: confirm reads its answer, y or anything else, from stdin
answer() {
    case "$1" in
        yes) replace_fn confirm 'echo "$1"' ;;
        no) replace_fn confirm 'echo "$1"; return 1' ;;
        stdin) replace_fn confirm 'local reply; echo "$1"; read -r reply; [ "$reply" == y ]' ;;
        *) fail "answer: '$1' isn't yes, no, or stdin" ;;
    esac
}

# The test's last line; a test that exits 0 without it fails
test_done() {
    TEST_DONE=true
}

# A gsettings keeping each key in $SANDBOX/gsettings/<schema>.<key>, in the GVariant text it was
# set to, which is what the steps pass; an unset key prints @as []. A schema listed in
# $SANDBOX/gsettings/no-schema is missing, as the dock's is on GNOME without Ubuntu's.
stub_gsettings() {
    mkdir -p "$SANDBOX/gsettings"
    stub gsettings "$(printf 'dir=%q' "$SANDBOX/gsettings")"'
file="$dir/${2//\//_}.$3"
! grep -qxF "$2" "$dir/no-schema" 2> /dev/null || { echo "No such schema “$2”" >&2; exit 1; }
case "$1" in
    get) cat "$file" 2> /dev/null || echo "@as []" ;;
    set) printf "%s\n" "$4" > "$file" ;;
esac'
}

# A GNOME session keeping its state in dir $1: stub_gsettings, GNOME Shell 50.1, busctl answering
# for the shell while $SHELL_STATE is set, with an extension in that state (unknown: none) and
# $SHELL_ERROR, and stub_systemctl_units on dir $1, with graphical-session.target active while
# $SESSION is set.
stub_gnome_session() {
    local state="$1" body
    mkdir -p "$state"
    stub_gsettings
    stub gnome-shell 'echo "GNOME Shell 50.1"'
    IFS= read -r -d '' body << 'EOF' || true
case "$*" in
    "--user status org.gnome.Shell") [ -n "${SHELL_STATE:-}" ] ;;
    *GetExtensionInfo*)
        if [ "$SHELL_STATE" == unknown ]; then echo "{\"type\":\"a{sv}\",\"data\":[{}]}"
        else echo "{\"type\":\"a{sv}\",\"data\":[{\"state\":{\"type\":\"d\",\"data\":$SHELL_STATE.0},\"error\":{\"type\":\"s\",\"data\":\"${SHELL_ERROR:-}\"}}]}"; fi ;;
esac
EOF
    stub busctl "$body"
    stub_systemctl_units "$state" \
        '[ "$*" != "--user is-active --quiet graphical-session.target" ] || { [ -n "${SESSION:-}" ]; exit; }'
}

# stub_systemctl_units <dir> [prefix-body]: a systemctl keeping each unit's state in <dir> as files
# a test can create or remove: <unit>.enabled, .active, .masked and .failed, named user-<unit>.* for
# --user units. enable --now leaves a failed unit failed; start and restart clear it. show answers LoadState (not-found while <unit>.not-found exists), NeedDaemonReload
# (yes while <dir>/reload-needed exists), ActiveState and UnitFileState. daemon-reload fails while
# <dir>/reload-fails exists, and else clears reload-needed and the not-found marks.
# show-environment fails while <dir>/no-user-manager exists. The prefix body runs first, with the
# args as "$@", and may handle a command and exit.
stub_systemctl_units() {
    local body
    mkdir -p "$1"
    IFS= read -r -d '' body << 'EOF' || true
user=""
[ "${1:-}" != --user ] || { user=user-; shift; }
cmd="${1:-}"
shift
now=false quiet=false value=false units=() props=()
while [ $# -gt 0 ]; do
    case "$1" in
        --now) now=true ;;
        -q | --quiet) quiet=true ;;
        --value) value=true ;;
        -p | --property) props+=("$2"); shift ;;
        --property=*) props+=("${1#*=}") ;;
        -*) ;;
        *) units+=("$1") ;;
    esac
    shift
done
say() { "$quiet" || echo "$1"; }
found=1
for unit in "${units[@]}"; do
    f="$dir/$user$unit"
    case "$cmd" in
        is-enabled)
            if [ -e "$f.masked" ]; then say masked
            elif [ -e "$f.enabled" ]; then say enabled; found=0
            else say disabled; fi ;;
        is-active) if [ -e "$f.active" ]; then say active; found=0; else say inactive; fi ;;
        is-failed) if [ -e "$f.failed" ]; then say failed; found=0; else say inactive; fi ;;
        enable)
            [ ! -e "$f.masked" ] || { echo "Failed to enable unit: Unit $unit is masked." >&2; exit 1; }
            touch "$f.enabled"
            ! "$now" || [ -e "$f.failed" ] || touch "$f.active" ;;
        disable) rm -f "$f.enabled"; ! "$now" || rm -f "$f.active" ;;
        start | restart | reload-or-restart)
            [ ! -e "$f.masked" ] || { echo "Failed to start $unit: Unit $unit is masked." >&2; exit 1; }
            rm -f "$f.failed"
            touch "$f.active" ;;
        try-restart | try-reload-or-restart) ;;
        stop) rm -f "$f.active" ;;
        mask) rm -f "$f.enabled"; touch "$f.masked"; ! "$now" || rm -f "$f.active" ;;
        unmask) rm -f "$f.masked" ;;
        reset-failed) rm -f "$f.failed" ;;
        show)
            for prop in "${props[@]}"; do
                case "$prop" in
                    LoadState)
                        if [ -e "$f.masked" ]; then v=masked; elif [ -e "$f.not-found" ]; then v=not-found; else v=loaded; fi ;;
                    NeedDaemonReload) if [ -e "$dir/reload-needed" ]; then v=yes; else v=no; fi ;;
                    ActiveState) if [ -e "$f.active" ]; then v=active; else v=inactive; fi ;;
                    UnitFileState)
                        if [ -e "$f.masked" ]; then v=masked; elif [ -e "$f.enabled" ]; then v=enabled; else v=disabled; fi ;;
                    *) v="" ;;
                esac
                if "$value"; then echo "$v"; else echo "$prop=$v"; fi
            done ;;
        *) echo "stub_systemctl_units: no $cmd" >&2; exit 1 ;;
    esac
done
case "$cmd" in
    is-enabled | is-active | is-failed) exit "$found" ;;
    show-environment) [ ! -e "$dir/no-user-manager" ] ;;
    daemon-reload)
        [ ! -e "$dir/reload-fails" ] || exit 1
        rm -f "${dir:?}/reload-needed" "${dir:?}"/*.not-found ;;
esac
EOF
    stub systemctl "$(printf 'dir=%q' "$1")
${2:-}
$body"
}

# A custom shortcut of yours, custom0 on Super+Return, which the steps' shortcuts must keep
user_shortcut() {
    local dir=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$dir/custom0/']"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$dir/custom0/" \
        binding "'<Super>Return'"
}

# fake_github_remotes <dir>: git fetches https://github.com/<owner>/<repo> from <dir>/<owner>/<repo>
fake_github_remotes() {
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$1/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/
}

git_commit() {
    local repo="$1"
    shift
    git -C "$repo" commit -q "$@"
}

in_terminal_available() {
    if [[ "$OSTYPE" == darwin* ]]; then
        command -v script &> /dev/null
    else
        script --version 2> /dev/null | grep -q util-linux
    fi
}

# Run a command with a terminal for stdin and stdout, and stdin at EOF. Its output loses script's
# \r line ends and the ^D that macOS's script echoes at EOF.
in_terminal() {
    if [[ "$OSTYPE" == darwin* ]]; then
        script -q /dev/null "$@"
    else
        # script runs the command with $SHELL, and %q output is bash quoting
        SHELL=/bin/bash script -qec "$(printf '%q ' "$@")" /dev/null
    fi < /dev/null | tr -d '\r\b' | sed 's/^^D//'
}

stub_login_shell_zsh() {
    stub dscl 'case "$*" in *UserShell*) echo "UserShell: /bin/zsh" ;; *) exit 1 ;; esac'
    stub getent 'echo "$2:x:1000:1000::$HOME:/usr/bin/zsh"'
    stub chsh 'exit 1'
}

# A uname that says $1, Darwin or Linux, and for -m $2, by default arm64 on Darwin and x86_64 on
# Linux. Unlike a stub, it doesn't log.
stub_uname() {
    local arch="${2:-}"
    if [ -z "$arch" ]; then
        arch=x86_64
        [ "$1" != Darwin ] || arch=arm64
    fi
    printf '%s\n' '#!/bin/bash' "case \"\${1:-}\" in -m) echo $arch ;; *) echo $1 ;; esac" > "$STUB_DIR/uname"
    chmod +x "$STUB_DIR/uname"
}

# Usage: fake_step <name> [body]: a step in $SANDBOX/steps that logs "<name> <args>" to
# $SANDBOX/ran, then runs the body. step_script then finds only fake steps; set STEPS for
# run_steps. Call it after load_script lib/common.sh and lib/runner.sh.
fake_step() {
    mkdir -p "$SANDBOX/steps"
    printf '%s\n' '#!/bin/bash' "echo \"$1\${*:+ \$*}\" >> \"$SANDBOX/ran\"" "${2:-}" > "$SANDBOX/steps/$1.sh"
    replace_fn step_script "$(printf 'local steps=%q' "$SANDBOX/steps")"'
[ -f "$steps/$1.sh" ] && echo "$steps/$1.sh"'
}

# dpkg --print-architecture says $1, by default amd64
stub_dpkg_arch() {
    stub dpkg '[ "$1" != --print-architecture ] || echo '"${1:-amd64}"
}

# stub_apt_packages [--apt-get <body>] [package...]: dpkg-query reports installed the packages
# listed in $SANDBOX/installed, which starts with these; a * line counts every package not listed
# as !<package>. apt-get install adds its packages, purge and remove take them out, and -s prints
# $SANDBOX/apt-upgrade. The body runs first in apt-get, with its args as "$@", and may exit.
# shellcheck disable=SC2120 # with no packages, none are installed
stub_apt_packages() {
    local body="" list="$SANDBOX/installed"
    if [ "${1:-}" == --apt-get ]; then
        body="$2"
        shift 2
    fi
    : > "$list"
    [ $# -eq 0 ] || printf '%s\n' "$@" > "$list"
    stub dpkg-query 'list="$SANDBOX/installed" status=0
for p in "$@"; do
    case "$p" in -*) continue ;; esac
    if grep -qxF "$p" "$list" || { grep -qxF "*" "$list" && ! grep -qxF "!$p" "$list"; }; then
        printf "install ok installed"
    else
        status=1
    fi
done
exit "$status"'
    stub apt-get "$body"'
list="$SANDBOX/installed" cmd="" simulate=false packages=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o | -c | -t) shift ;;
        -s | --simulate) simulate=true ;;
        -*) ;;
        *) if [ -z "$cmd" ]; then cmd="$1"; else packages+=("$1"); fi ;;
    esac
    shift
done
if "$simulate"; then
    cat "$SANDBOX/apt-upgrade" 2> /dev/null || true
    exit 0
fi
for p in ${packages[@]+"${packages[@]}"}; do
    others="$(grep -vxF -e "$p" -e "!$p" "$list" || true)"
    case "$cmd" in
        install) { [ -z "$others" ] || echo "$others"; echo "$p"; } > "$list" ;;
        purge | remove)
            { [ -z "$others" ] || echo "$others"; } > "$list"
            ! grep -qxF "*" "$list" || echo "!$p" >> "$list" ;;
    esac
done'
}

# A gpg listing a key with fingerprint $1, as --show-keys --with-colons does, and with $2 a subkey
# with that fingerprint
stub_gpg_fpr() {
    local body="printf 'pub:-\\nfpr:::::::::%s:\\n' $1"
    [ -z "${2:-}" ] || body="$body
printf 'sub:-\\nfpr:::::::::%s:\\n' $2"
    stub gpg "$body"
}

# A curl answering a release check with the HTTP status in $SANDBOX/http-status, which this sets
# to $1, by default 200
stub_http_status() {
    echo "${1:-200}" > "$SANDBOX/http-status"
    stub curl 'cat "$SANDBOX/http-status"'
}

# stub_fetch [content]: replaces fetch, which logs "fetch <url>", fails while $SANDBOX/fetch-fails
# exists, and else writes the content, by default "key", to the file.
# stub_fetch <url prefix>=<path>...: a curl, which a script run as its own process also gets,
# serving a URL from the first prefix it starts with: the path plus the rest of the URL, to the
# file -o names, or else to stdout. A URL no prefix maps to an existing file fails as a 404 does,
# and every URL as an unreachable host does while $SANDBOX/fetch-fails exists.
stub_fetch() {
    local map
    case "${1:-}" in
        *=*) ;;
        *)
            replace_fn fetch 'echo "fetch $1" >> "$STUB_LOG"
[ ! -e "$SANDBOX/fetch-fails" ] || return 1
echo '"$(printf '%q' "${1:-key}")"' > "$2"'
            return 0
            ;;
    esac
    : > "$SANDBOX/fetch-map"
    for map; do
        printf '%s\t%s\n' "${map%=*}" "${map##*=}" >> "$SANDBOX/fetch-map"
    done
    stub curl 'out="" file="" url="${!#}"
while [ $# -gt 0 ]; do
    [ "$1" != -o ] || { out="$2"; shift; }
    shift
done
[ ! -e "$SANDBOX/fetch-fails" ] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }
tab="$(printf "\t")"
while IFS="$tab" read -r prefix path; do
    case "$url" in "$prefix"*) file="$path${url#"$prefix"}"; break ;; esac
done < "$SANDBOX/fetch-map"
[ -n "$file" ] && [ -f "$file" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi'
}

# Usage: jq_edit <file> <jq args>...: edits the file in place, as you would by hand
jq_edit() {
    local file="$1"
    shift
    jq "$@" "$file" > "$SANDBOX/jq_edit.json" && cp "$SANDBOX/jq_edit.json" "$file"
}

# Check syntax first: a sourced syntax error would end the test with status 0 under bash 3.2
load_script() {
    local script="$REPO_DIR/$1" f
    shift
    for f in "$script" "$REPO_DIR/lib/common.sh" "$REPO_DIR/lib/system.sh"; do
        if ! "$BASH" -n "$f"; then
            echo "Syntax error in $f" >&2
            exit 2
        fi
    done
    # lib/common.sh defines its default main only when none exists
    case "$script" in
        "$REPO_DIR"/lib/*.sh) ;;
        *) unset -f main ;;
    esac
    # Else an earlier step's values would gate this one
    unset STEP_OS STEP_NEEDS
    # shellcheck source=/dev/null
    source "$script" "$@"
    _stubs_first
}

# Usage: sandbox_paths [NAME=value]... <script>...: sets each NAME=value, then points every other
# upper-case constant the scripts set whose value, or an element of it, starts with /etc, /var,
# /usr, /run or /dev at the same path under $SANDBOX, as /etc/x becomes $SANDBOX/etc/x. Scripts are
# repo-relative and may be globs. Call it after each load_script, which resets the constants. It
# fails the test on any it couldn't move, such as a colon list; set those.
sandbox_paths() {
    local arg name value values moved files=() set=" " left=""
    for arg; do
        case "$arg" in
            [A-Z]*=*)
                printf -v "${arg%%=*}" '%s' "${arg#*=}"
                set="$set${arg%%=*} "
                ;;
            *)
                # shellcheck disable=SC2206 # a glob
                files+=("$REPO_DIR"/$arg)
                ;;
        esac
    done
    while IFS= read -r name; do
        case "$set" in *" $name "*) continue ;; esac
        eval "values=(\${${name}[@]+\"\${${name}[@]}\"})"
        moved=()
        for value in ${values[@]+"${values[@]}"}; do
            case "$value" in
                # A checkout under /var, as mktemp's dirs are on macOS
                "$REPO_DIR"/*) ;;
                /etc | /etc/* | /var | /var/* | /usr | /usr/* | /run | /run/* | /dev | /dev/*)
                    case "$value" in
                        *:*) left="$left $name=$value" ;;
                        *) value="$SANDBOX$value" ;;
                    esac
                    ;;
            esac
            moved+=("$value")
        done
        [ ${#moved[@]} -gt 0 ] || continue
        if [[ "$(declare -p "$name")" == "declare -a"* ]]; then
            eval "$name=(\"\${moved[@]}\")"
        else
            printf -v "$name" '%s' "${moved[0]}"
        fi
    done < <(sed -nE 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "${files[@]}" | sort -u)
    [ -z "$left" ] || fail "sandbox_paths left these on the real machine:$left"
}

# Empty $STUB_LOG, then run under set -e in a subshell, setting RUN_OUTPUT and RUN_STATUS; always
# succeeds. To check the log of two runs, save it before the second.
run() {
    local errexit=false
    : > "$STUB_LOG"
    case "$-" in *e*) errexit=true ;; esac
    set +e
    RUN_OUTPUT="$(
        set -e
        "$@" 2>&1
    )"
    RUN_STATUS=$?
    if "$errexit"; then
        set -e
    fi
    return 0
}

fail() {
    local i=1
    TEST_FAILURES=$((TEST_FAILURES + 1))
    while [ "${BASH_SOURCE[$i]:-}" == "${BASH_SOURCE[0]}" ]; do
        i=$((i + 1))
    done
    echo "FAIL ${BASH_SOURCE[$i]##*/}:${BASH_LINENO[$((i - 1))]}: $1" >&2
}

# Builtins only, so it works after hide
_show() {
    local line
    [ -n "$1" ] || return 0
    while IFS= read -r line; do
        printf '    %s\n' "$line" >&2
    done <<< "$1"
}

assert_eq() {
    [ "$1" == "$2" ] && return 0
    fail "${3:-values differ}: expected '$1', got '$2'"
    return 0
}

assert_contains() {
    [[ "$1" == *"$2"* ]] && return 0
    fail "${3:-output} doesn't contain '$2'. It was:"
    _show "$1"
    return 0
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] && return 0
    fail "${3:-output} contains '$2'. It was:"
    _show "$1"
    return 0
}

assert_file_contains() {
    if [ ! -f "$1" ]; then
        fail "$1 doesn't exist"
    elif ! grep -qF -- "$2" "$1"; then
        fail "$1 doesn't contain '$2'. It has:"
        _show "$(cat "$1")"
    fi
    return 0
}

assert_file_not_contains() {
    if [ -f "$1" ] && grep -qF -- "$2" "$1"; then
        fail "$1 contains '$2'"
    fi
    return 0
}

# Usage: diag <check> [args]: one status check, such as status_smart, exiting as status does
diag() {
    "$@"
    status_result
}

# Fails if $STUB_LOG has a sudo without -n, which could prompt. $1 says what ran it.
assert_sudo_noninteractive() {
    local prompting
    prompting="$(grep '^sudo' "$STUB_LOG" | grep -v '^sudo -n ' || true)"
    [ -z "$prompting" ] && return 0
    fail "${1:-status} ran sudo without -n:"
    _show "$prompting"
    return 0
}

# Commands that change the machine, as $STUB_LOG logs them, with or without sudo; apt-get -s only
# simulates. A sudo running anything but SUDO_READS changes it too.
CHANGES_MACHINE="systemctl ([^ ]+ )*(start|stop|restart|try-restart|reload|reload-or-restart|try-reload-or-restart|enable|disable|mask|unmask|daemon-reload|reset-failed|kill)
fwupdmgr (refresh|update|install|upgrade)
smartctl .* (-t|--test)
docker ([^ ]+ )*(prune|stop|start|restart|rm|kill|run)
apt-get ([^ ]+ )*(install|purge|remove|autoremove|update|upgrade|full-upgrade|dist-upgrade)
apt-mark (hold|unhold)
snap (install|remove|refresh)
brew ([^ ]+ )*(install|reinstall|upgrade|uninstall|tap|untap)
mas (install|get|upgrade|uninstall)
softwareupdate .*(-i|--install)
xcode-select --install
mise (install|use|uninstall|upgrade|prune)
uv tool (install|upgrade|uninstall)
rustup (install|update|default|toolchain install|component add|target add|self update)
pnpm (install|i|add|remove|update)
npm (install|i|uninstall|update)
pkill
killall
launchctl (bootstrap|bootout|kickstart|load|unload|enable|disable|kill)
defaults (write|delete|import)
osascript .*quit
open
xdg-open
gsettings (set|reset)
dconf (write|reset|load)
gnome-extensions (enable|disable|install|uninstall)
chsh
usermod
useradd
userdel
groupadd
gpasswd
passwd
chpasswd
loginctl (enable-linger|disable-linger|terminate-[a-z]+|kill-[a-z]+)
locale-gen
sysctl (--system|-w|-p|--load)
ufw (allow|deny|reject|limit|prepend|insert|delete|default|enable|disable|reload|reset|route|--force)
nmcli (connection|con|c) (modify|mod|up|down|add|delete|reload)
tailscale (up|down|set|login|logout)"
SUDO_READS="true|cat|test|sh -c|bash -c|sshd -T|ufw status|docker (system df|ps)|smartctl (-H|--scan)"

# Usage: machine_changes <log>: prints the log's lines for commands that change the machine
machine_changes() {
    local changes
    changes="^(sudo (-n )?)?([^ ]*/)?($(tr '\n' '|' <<< "$CHANGES_MACHINE" | sed 's/|$//'))( |$)"
    {
        grep -E "$changes" "$1" | grep -vE '^(sudo (-n )?)?([^ ]*/)?apt-get( [^ ]+)* (-s|--simulate)( |$)' || true
        grep -E '^sudo ' "$1" | grep -vE "^sudo (-n )?([^ ]*/)?($SUDO_READS)( |$)" || true
    } | awk '!seen[$0]++'
}

# Usage: assert_read_only <status> <cmd>...: assert_exit, and fails if the command ran a sudo that
# could prompt, or changed the machine
assert_read_only() {
    local changes
    assert_exit "$@"
    shift
    assert_sudo_noninteractive "'$*'"
    changes="$(machine_changes "$STUB_LOG")"
    [ -z "$changes" ] && return 0
    fail "'$*' changed the machine:"
    _show "$changes"
    return 0
}

# Usage: assert_idempotent [--ignore <path>]... <cmd>...: runs the command twice, each run
# succeeding, and fails if the second changed the sandbox (a path, mode, symlink target, or file's
# content, but not a time) or the machine. --ignore leaves out a file the command rewrites on every
# run, such as a log. Leaves the second run's $RUN_OUTPUT and $STUB_LOG, and the first's output and
# log in $FIRST_OUTPUT and $FIRST_LOG.
assert_idempotent() {
    local ignores=() before after changes
    while [ "${1:-}" == --ignore ]; do
        case "$2" in
            "$SANDBOX"/*) ignores+=("./${2#"$SANDBOX"/}") ;;
            *)
                fail "assert_idempotent: $2 isn't in the sandbox"
                return 0
                ;;
        esac
        shift 2
    done
    run "$@"
    # shellcheck disable=SC2034 # tests read them
    FIRST_OUTPUT="$RUN_OUTPUT" FIRST_LOG="$(cat "$STUB_LOG")"
    if [ "$RUN_STATUS" != 0 ]; then
        fail "'$*' exited $RUN_STATUS on its first run. Its output:"
        _show "$RUN_OUTPUT"
        return 0
    fi
    before="$(_sandbox_tree ${ignores[@]+"${ignores[@]}"})"
    run "$@"
    after="$(_sandbox_tree ${ignores[@]+"${ignores[@]}"})"
    if [ "$RUN_STATUS" != 0 ]; then
        fail "'$*' exited $RUN_STATUS on its second run. Its output:"
        _show "$RUN_OUTPUT"
    fi
    if [ "$before" != "$after" ]; then
        fail "'$*' changed the sandbox on its second run (< before, > after):"
        _show "$(diff <(echo "$before") <(echo "$after") | grep '^[<>]')"
    fi
    changes="$(machine_changes "$STUB_LOG")"
    if [ -n "$changes" ]; then
        fail "'$*' changed the machine on its second run:"
        _show "$changes"
    fi
    return 0
}

# Each path in the sandbox but $STUB_LOG and the given ./<path>s, sorted: its mode and path, with a
# symlink's target, and each file's checksum, or why it can't be read
_sandbox_tree() {
    local prune=(-path "./${STUB_LOG#"$SANDBOX"/}") path
    for path; do
        prune+=(-o -path "$path")
    done
    (
        cd "$SANDBOX" || exit 1
        # ls -ln's fields up to the path: mode, links, user, group, size, and three for the time
        LC_ALL=C find . \( "${prune[@]}" \) -prune -o -exec /bin/ls -ldn {} + 2>&1 |
            awk '{ mode = $1; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, ""); print mode, $0 }'
        find . \( "${prune[@]}" \) -prune -o -type f -exec cksum {} + 2>&1
    ) | LC_ALL=C sort || true
}

# snapshot <file> saves a copy for assert_unchanged <file> <when>, which fails if it now differs
snapshot() {
    mkdir -p "$SANDBOX/snapshots"
    cp "$1" "$(_snapshot_path "$1")"
}

assert_unchanged() {
    cmp -s "$(_snapshot_path "$1")" "$1" && return 0
    fail "$1 changed ${2:-since its snapshot}"
    return 0
}

_snapshot_path() {
    printf '%s/snapshots/%s\n' "$SANDBOX" "$(printf '%s' "$1" | tr / %)"
}

# Usage: as_unwritable <path> <cmd>...: asserts the command fails with the path read-only, leaving
# $RUN_OUTPUT, then makes it writable again. Fails, running nothing, when it's writable anyway, as
# to root.
as_unwritable() {
    local path="$1"
    shift
    chmod a-w "$path"
    if [ ! -w "$path" ]; then
        assert_exit 1 "$@"
        chmod u+w "$path"
        return 0
    fi
    chmod u+w "$path"
    return 1
}

# Poll the command every 0.1 s until it succeeds; fails after 10 s
wait_for() {
    local i=0
    until "$@"; do
        [ "$i" -lt 100 ] || return 1
        sleep 0.1
        i=$((i + 1))
    done
}

# Succeeds once the process has exited. kill -0 still finds a zombie, so check ps.
process_exited() {
    case "$(ps -o stat= -p "$1" 2> /dev/null)" in
        '' | Z*) return 0 ;;
    esac
    return 1
}

# Leaves $RUN_OUTPUT for further checks
assert_exit() {
    local expected="$1"
    shift
    run "$@"
    [ "$RUN_STATUS" == "$expected" ] && return 0
    fail "'$*' exited $RUN_STATUS, not $expected. Its output:"
    _show "$RUN_OUTPUT"
    return 0
}

setup_sandbox
