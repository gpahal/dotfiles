# Test helpers. A test sources this, calls setup_sandbox, runs steps or load_script, checks with
# assert_*, and ends with test_done. Stub every SENTINELS command it reaches; hide makes one missing.
# Change a loaded function only with replace_fn, wrap_fn, as_os macos|ubuntu, or answer yes|no.
# tests/run.sh covers skips, timeouts, and the serial and os marks.
# shellcheck shell=bash

TESTS_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
TEST_FAILURES=0
TEST_SKIPPED=false
TEST_DONE=false

# shellcheck source=sentinels.sh
source "$TESTS_DIR/sentinels.sh"

# Sets the EXIT trap; a test adds to it with on_exit rather than setting its own.
setup_sandbox() {
    local var
    # /tmp keeps tmux's socket path under macOS's limit; -P makes printed paths match $HOME
    SANDBOX="$(cd -P "$(mktemp -d "${TEST_SANDBOX_PARENT:-/tmp}/dotfiles-test.XXXXXX")" && pwd)"
    trap _sandbox_exit EXIT
    # GIT_* from a hook or worktree would point git at the real repo or add config
    for var in $(compgen -e | grep -E '^(XDG_|DOTFILES_|GIT_)' || true); do
        unset "$var"
    done
    unset CDPATH BASH_ENV TMUX TMUX_PANE ZDOTDIR CODEX_HOME CLAUDE_CONFIG_DIR SSH_AUTH_SOCK \
        SSH_USER_AUTH SSH_CONNECTION SSH_CLIENT SSH_TTY MISE_DATA_DIR MISE_CONFIG_DIR \
        MISE_GLOBAL_CONFIG_FILE MISE_STATE_DIR MISE_CACHE_DIR
    # A test that clones rewrites the url to a local repo, as fake_tmux_plugins does
    export GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
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
    # Real free space would sway status reports
    stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
for path in "$@"; do case "$path" in -*) ;; *) echo "/dev/test 1048576000 104857600 943718400 10% $path" ;; esac; done'
    exec < /dev/null
}

_sandbox_exit() {
    local status=$? hook
    # Subshell, so a failing hook can't stop the cleanup
    for hook in ${_ON_EXIT[@]+"${_ON_EXIT[@]}"}; do
        (eval "$hook") || true
    done
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

# Eval a command at exit, for what the test starts in another process group, which signals miss
_ON_EXIT=()
on_exit() {
    _ON_EXIT+=("$1")
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
    local name="$1" body="${2:-}"
    printf '%s\n' '#!/bin/bash' 'printf '"'%s\\n'"' "${0##*/}${*:+ $*}" >> "$STUB_LOG"' "$body" > "$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

# Stub sudo to run its command as you. It refuses paths outside the sandbox and repo files the
# command would change. The optional body runs first and may rewrite "$@" with set --.
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
i=0
for arg in "$@"; do
    i=$((i + 1))
    case "$arg" in
        /dev/null | "$sandbox" | "$sandbox"/* | *=/dev/null | *="$sandbox" | *="$sandbox"/*) ;;
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
    [ -e "'"$SANDBOX"'/sudo-cached" ] || exit 1
    shift
fi
'"${1:-}"
}

cache_sudo() {
    case "$1" in
        yes) touch "$SANDBOX/sudo-cached" ;;
        no) rm -f "$SANDBOX/sudo-cached" ;;
        *) fail "cache_sudo: '$1' isn't yes or no" ;;
    esac
}

# Stub `apt-config shell`; the body prints the config as `apt-config dump` would
stub_apt_config() {
    stub apt-config "config() {
${1:-:}
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

# A step run as its own process needs a uname stub instead
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

answer() {
    case "$1" in
        yes) replace_fn confirm 'echo "$1"' ;;
        no) replace_fn confirm 'echo "$1"; return 1' ;;
        *) fail "answer: '$1' isn't yes or no" ;;
    esac
}

# The test's last line; a test that exits 0 without it fails
test_done() {
    TEST_DONE=true
}

# A gsettings keeping each key in a file, printing values as gsettings does: a list as set, and a
# string in single quotes, or double quotes when it holds a single one. set takes a string quoted
# that way too, and, like gsettings, fails on a quoted string followed by more. Unset keys print
# GNOME's defaults for the lists the steps edit, else ''.
stub_gsettings() {
    local body
    mkdir -p "$SANDBOX/gsettings"
    # Not a heredoc in $(...): bash 3.2 misparses the case patterns' ) there
    IFS= read -r -d '' body << 'STUB' || true
file="$dir/${2//\//_}.$3"
case "$1" in
    get)
        if [ -e "$file" ]; then cat "$file"
        else case "$3" in
            enabled-extensions | custom-keybindings) echo "@as []" ;;
            switch-input-source) echo "['<Super>space', 'XF86Keyboard']" ;;
            *) echo "''" ;;
        esac; fi ;;
    set)
        case "$4" in
            "["* | "@as"*) printf "%s\n" "$4" > "$file" ;;
            \'* | \"*)
                # Without its escapes, a quoted string has its quote only at the end
                quote="${4:0:1}" rest="${4:1}"
                rest="${rest//\\\\/}"
                rest="${rest//\\$quote/}"
                if [ "${rest%%"$quote"*}$quote" != "$rest" ]; then
                    echo "expected end of input:" >&2
                    exit 1
                fi
                printf "%s\n" "$4" > "$file" ;;
            *"'"*) printf '"%s"\n' "$4" > "$file" ;;
            *) printf "'%s'\n" "$4" > "$file" ;;
        esac ;;
esac
STUB
    stub gsettings "$(printf 'dir=%q' "$SANDBOX/gsettings")
$body"
}

# The sandbox has no git identity
git_commit() {
    local repo="$1"
    shift
    git -C "$repo" -c user.name=test -c user.email=test@example.com commit -q "$@"
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

# Local repos stand in for GitHub; each plugin is pinned to its first commit, not HEAD
fake_tmux_plugins() {
    local repo sha remote n
    FAKE_PLUGIN_REMOTES="$SANDBOX/remotes"
    export DOTFILES_TMUX_PLUGINS_LOCK="$SANDBOX/plugins.lock"
    echo "# Test pins" > "$DOTFILES_TMUX_PLUGINS_LOCK"
    while read -r repo _; do
        remote="$FAKE_PLUGIN_REMOTES/$repo"
        git init -q "$remote"
        for n in 1 2; do
            echo "$repo $n" > "$remote/README"
            git -C "$remote" add README
            git_commit "$remote" -m "$n"
            [ "$n" -eq 2 ] || sha="$(git -C "$remote" rev-parse HEAD)"
        done
        echo "$repo $sha" >> "$DOTFILES_TMUX_PLUGINS_LOCK"
    done < <(awk '!/^#/ && NF' "$REPO_DIR/tmux/plugins.lock")
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$FAKE_PLUGIN_REMOTES/.insteadOf"
    export GIT_CONFIG_VALUE_0=https://github.com/
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
        "$REPO_DIR/lib/common.sh" | "$REPO_DIR/lib/system.sh") ;;
        *) unset -f main ;;
    esac
    # Else an earlier step's values would gate this one
    unset STEP_OS STEP_NEEDS
    # shellcheck source=/dev/null
    source "$script" "$@"
    _stubs_first
}

# Usage: ntfy_hook_copy <hook> <url-file> <lib> <dest>. Root's hooks hard-code their paths and
# PATH, so the copy points them at the sandbox.
ntfy_hook_copy() {
    sed -e "s|^NTFY_URL_FILE=.*|NTFY_URL_FILE=\"$2\"|" -e "s|^NTFY_LIB=.*|NTFY_LIB=\"$3\"|" \
        -e "s|^PATH=.*|PATH=\"$PATH\"|" "$REPO_DIR/$1" > "$4"
    if ! grep -qxF "NTFY_URL_FILE=\"$2\"" "$4" || ! grep -qxF "NTFY_LIB=\"$3\"" "$4" ||
        ! grep -qxF "PATH=\"$PATH\"" "$4"; then
        fail "$1 has no NTFY_URL_FILE=, NTFY_LIB=, or PATH= line to point at the sandbox"
    fi
}

# Run under set -e in a subshell, setting RUN_OUTPUT and RUN_STATUS; always succeeds
run() {
    local errexit=false
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

# Fails if $STUB_LOG has a sudo without -n, which could prompt. $1 says what ran it.
assert_sudo_noninteractive() {
    local prompting
    prompting="$(grep '^sudo' "$STUB_LOG" | grep -v '^sudo -n ' || true)"
    [ -z "$prompting" ] && return 0
    fail "${1:-status} ran sudo without -n:"
    _show "$prompting"
    return 0
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
