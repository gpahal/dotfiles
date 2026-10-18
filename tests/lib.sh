# Helpers for the tests in tests/. Source it from a test-*.sh file, call setup_sandbox, then run
# steps or load_script their functions, and check the results with the assert_* functions, and
# end with test_done. A failed assertion prints why and the test carries on; the test exits 1 at
# the end. Bash 3.2.
#
# setup_sandbox gives the test a temp HOME and puts a failing sentinel first on PATH for each
# command in SENTINELS. Stub every one the test reaches. hide makes a command missing. A sudo that
# runs its command is stub_sudo_exec, checks run in a subshell go through subtest, and what the
# test starts in another process group is stopped by on_exit. A test that lacks a tool it needs
# calls skip. tests/run.sh runs each test and says how skips and timeouts count.
# shellcheck shell=bash

TESTS_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
TEST_FAILURES=0
TEST_SKIPPED=false
TEST_DONE=false

# SENTINELS: the commands a test must stub
# shellcheck source=sentinels.sh
source "$TESTS_DIR/sentinels.sh"

# Point HOME, TMUX_TMPDIR, WORKTREES_DIR, and TMPDIR at a new temp dir, unset the variables that
# would send a step elsewhere (XDG_*, GIT_*, CODEX_HOME, CDPATH, ...), limit git to local repos,
# put $STUB_DIR first on PATH, and read stdin from /dev/null, so confirm says no.
# sudo is stubbed to fail, as it does when not cached, so no test runs it for real, even on a CI
# runner with passwordless sudo. A test may stub its own. Every command in SENTINELS gets a
# failing sentinel (see _sentinels). Sets an EXIT trap that removes the
# temp dir and makes the test exit 1 when an assertion failed or a sentinel ran, so a test mustn't
# set its own; on_exit adds to it.
setup_sandbox() {
    local var
    # /tmp, not $TMPDIR, keeps tmux's socket path under its length limit on macOS. -P resolves
    # /tmp to /private/tmp there, so paths the steps print match $HOME. tests/run.sh sets
    # TEST_SANDBOX_PARENT to the test's own dir under /tmp, which it removes even when its
    # watchdog SIGKILLs the test before the EXIT trap can.
    SANDBOX="$(cd -P "$(mktemp -d "${TEST_SANDBOX_PARENT:-/tmp}/dotfiles-test.XXXXXX")" && pwd)"
    trap _sandbox_exit EXIT
    # GIT_* covers what a git hook, a worktree, or `git -c` exports: GIT_DIR and GIT_WORK_TREE
    # would point the steps' git at the real repo, and GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT,
    # and GIT_CONFIG_KEY_n/VALUE_n would add config, such as a url rewrite, to every git command
    for var in $(compgen -e | grep -E '^(XDG_|DOTFILES_|GIT_)' || true); do
        unset "$var"
    done
    # SSH_AUTH_SOCK would let ssh-add and ssh reach the real agent and its keys, and the ubuntu
    # step reads the real SSH session's login from SSH_USER_AUTH.
    # BASH_ENV would run a file in every bash a step starts, and MISE_* would point mise at the
    # real config and state.
    unset CDPATH BASH_ENV TMUX TMUX_PANE ZDOTDIR CODEX_HOME CLAUDE_CONFIG_DIR SSH_AUTH_SOCK \
        SSH_USER_AUTH SSH_CONNECTION SSH_CLIENT SSH_TTY MISE_DATA_DIR MISE_CONFIG_DIR \
        MISE_GLOBAL_CONFIG_FILE MISE_STATE_DIR MISE_CACHE_DIR
    # git reads no system config, and reaches only local repos, never the network. A test that
    # clones sets its own GIT_CONFIG_COUNT url rewrite to a local repo, as fake_tmux_plugins does
    # for the tmux plugins.
    export GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
    export HOME="$SANDBOX/home" TMUX_TMPDIR="$SANDBOX/tmux" WORKTREES_DIR="$SANDBOX/worktrees"
    # mktemp's files go with the sandbox, among them the new contents a failed write_back keeps.
    # macOS's mktemp ignores TMPDIR without a template, so a wrapper below gives it one.
    export TMPDIR="$SANDBOX/tmp"
    # Set, so zsh/path.zsh doesn't set the real Homebrew's environment, and pointing nowhere, so
    # it puts no real Homebrew dir ahead of the stubs
    export HOMEBREW_PREFIX="$SANDBOX/no-homebrew"
    # The apt sources directory, where tests point the steps' apt sources, and the release
    # ubuntu_codename reads, so no test sees the host's. A step that sets its own paths needs the
    # test to override them.
    export APT_SOURCES_DIR="$SANDBOX/apt/sources.list.d" OS_RELEASE="$SANDBOX/os-release"
    mkdir -p "$APT_SOURCES_DIR"
    printf '%s\n' ID=ubuntu VERSION_ID='"26.04"' VERSION_CODENAME=resolute UBUNTU_CODENAME=resolute > "$OS_RELEASE"
    export STUB_DIR="$SANDBOX/stubs" STUB_LOG="$SANDBOX/stub.log"
    mkdir -p "$HOME" "$TMUX_TMPDIR" "$WORKTREES_DIR" "$TMPDIR" "$STUB_DIR"
    : > "$STUB_LOG"
    # Not a stub, so it logs nothing: a bare mktemp or mktemp -d gets a template under $TMPDIR
    printf '%s\n' '#!/bin/bash' \
        "case \"\$*\" in '' | -d) exec $(command -v mktemp) \"\$@\" \"\$TMPDIR/tmp.XXXXXXXXXX\" ;; esac" \
        "exec $(command -v mktemp) \"\$@\"" > "$STUB_DIR/mktemp"
    chmod +x "$STUB_DIR/mktemp"
    _stubs_first
    # shellcheck disable=SC2086 # a list of names
    _sentinels $SENTINELS
    stub sudo 'exit 1'
    # The PAM config the macos step's status and the Touch ID script read, so none sees the host's
    export DOTFILES_PAM_DIR="$SANDBOX/pam.d" DOTFILES_PAM_MODULES_DIR="$SANDBOX/pam-modules" \
        DOTFILES_PAM_LOCAL_MODULES_DIR="$SANDBOX/pam-local-modules"
    # The real free space would decide whether a status report needs attention, so df reports
    # each path it's given on a filesystem with 900 of 1000 GiB free
    stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
for path in "$@"; do case "$path" in -*) ;; *) echo "/dev/test 1048576000 104857600 943718400 10% $path" ;; esac; done'
    exec < /dev/null
}

_sandbox_exit() {
    local status=$? hook
    # Each in a subshell, so one that fails, even under set -u, can't stop the cleanup below
    for hook in ${_ON_EXIT[@]+"${_ON_EXIT[@]}"}; do
        (eval "$hook") || true
    done
    # A sentinel that ran under `|| true` or in a command expected to fail still fails the test
    if [ -s "$SANDBOX/unstubbed.log" ]; then
        echo "Commands ran that the test didn't stub:" >&2
        _show "$(cat "$SANDBOX/unstubbed.log")"
        TEST_FAILURES=$((TEST_FAILURES + 1))
    fi
    # A tmux server a test started lives on after its socket's directory is gone
    _stop_tmux_servers
    case "${SANDBOX:-}" in
        */dotfiles-test.*)
            chmod -R u+w "$SANDBOX" 2>/dev/null || true
            rm -rf "$SANDBOX"
            ;;
    esac
    # When set -u stops a script, bash 3.2 gives the EXIT trap a $? of 0, so a test that exits 0
    # without reaching test_done stopped early
    if [ "$status" -eq 0 ] && ! "$TEST_DONE"; then
        echo "The test stopped before its test_done line" >&2
        status=1
    fi
    if [ "$TEST_FAILURES" -gt 0 ]; then
        echo "$TEST_FAILURES check(s) failed" >&2
        # A test that failed, then skipped the rest, failed
        [ "$status" -ne 0 ] && [ "$status" -ne 77 ] || status=1
    elif [ "$status" -eq 0 ] && "$TEST_SKIPPED"; then
        status=77
    fi
    exit "$status"
}

# Run a command when the test exits, before the sandbox goes: after test_done, when set -e stops
# it, or on the SIGTERM tests/run.sh sends on a timeout or Ctrl-C. It's for what the test starts in
# another process group, which those signals don't reach. The command is a string evaluated then,
# so its variables have their values at exit. Commands run in the order added; failures are
# ignored.
# e.g. on_exit 'kill -- "-$SERVER_PID" 2> /dev/null'
_ON_EXIT=()
on_exit() {
    _ON_EXIT+=("$1")
}

# Stop every tmux server with a socket under $TMUX_TMPDIR, and wait up to 5 s for it and its
# panes' processes to exit. kill-server returns first, and a pane's shell can still write to HOME
# as it exits, as macOS's zsh writes ~/.zsh_history, which would race removing the sandbox.
_stop_tmux_servers() {
    local sock pids="" pid i=0 alive
    command -v tmux &>/dev/null || return 0
    for sock in "$TMUX_TMPDIR"/tmux-*/*; do
        [ -S "$sock" ] || continue
        # A stale socket's server is gone, so list-panes fails, which mustn't end the EXIT trap
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

# Put $STUB_DIR back at the front of PATH. lib/common.sh prepends Homebrew's and mise's
# directories, which would hide the stubs.
_stubs_first() {
    local path=":$PATH:"
    path="${path//:$STUB_DIR:/:}"
    path="${path#:}"
    export PATH="$STUB_DIR:${path%:}"
}

# Write an executable stub for a command to $STUB_DIR. It appends "<cmd> <args>" to $STUB_LOG,
# then runs the body, a Bash snippet that gets the stub's arguments as "$@". Without a body it
# succeeds and prints nothing.
# e.g. stub systemctl '[ "$2" != is-active ] || echo active'
stub() {
    local name="$1" body="${2:-}"
    # shellcheck disable=SC2016 # expanded by the stub
    printf '%s\n' '#!/bin/bash' 'printf '"'%s\\n'"' "${0##*/}${*:+ $*}" >> "$STUB_LOG"' "$body" > "$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

# Stub sudo to run its command as you, as sudo with cached credentials would, after dropping a
# leading -n. It refuses a command with an absolute path, alone or after an =, outside the sandbox
# (which holds $STUB_DIR), other than /dev/null and the repo's files. So a system path the test
# didn't point into the sandbox fails the command, rather than being written to as you. The
# optional body runs first, with sudo's arguments as "$@", as a stub's does, and may change them
# with set --, as to drop options that need root.
# e.g. stub_sudo_exec '[ "$*" != "-n true" ] || [ -n "${SUDO_CACHED:-}" ] || exit 1'
stub_sudo_exec() {
    # shellcheck disable=SC2016 # expanded by the stub
    stub sudo "${1:-}
$(printf 'sandbox=%q repo=%q' "$SANDBOX" "$REPO_DIR")"'
[ "${1:-}" != -n ] || shift
for arg in "$@"; do
    case "$arg" in
        /dev/null | "$sandbox" | "$sandbox"/* | "$repo"/* | *=/dev/null | *="$sandbox" | *="$sandbox"/* | *="$repo"/*) ;;
        /* | *=/*)
            echo "refused: $arg is outside the sandbox" >&2
            exit 1
            ;;
    esac
done
exec env "$@"'
}

# Stub apt-config shell, which takes <var> <key> pairs and prints <var>='<value>' for each key
# that's set. The body prints the config as apt-config dump does, one 'Key "value";' line per
# setting; the last line for a key wins.
# e.g. stub_apt_config 'echo "APT::Periodic::Unattended-Upgrade \"1\";"'
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

# Write a sentinel for each command to $STUB_DIR: it logs "<cmd> <args>" to $SANDBOX/unstubbed.log,
# says so on stderr, and exits 127, as a missing command would. The log is outside $STUB_DIR, so
# a step that runs a sentinel with HOME or the environment changed still logs it. stub replaces a
# sentinel. Every test writes about 60, so printf writes them and one chmod marks them all.
_sentinels() {
    local cmd body
    # shellcheck disable=SC2016 # expanded by the sentinel
    body="$(printf '#!/bin/bash\nlog=%q\n' "$SANDBOX/unstubbed.log")"'
printf '"'%s\\n'"' "${0##*/}${*:+ $*}" >> "$log"
echo "unstubbed command: ${0##*/}" >&2
exit 127'
    for cmd; do
        printf '%s\n' "$body" > "$STUB_DIR/$cmd"
    done
    [ $# -eq 0 ] || (cd "$STUB_DIR" && chmod +x "$@")
}

# Make commands missing for the rest of the test, even where they're installed: PATH becomes
# $STUB_DIR and a dir of links to every other command on PATH, and the commands' stubs and
# sentinels go. lib/common.sh puts Homebrew's dirs on PATH when it finds no brew, so hide brew
# exports DOTFILES_NO_LOAD_BREW, which stops that in sourced scripts and in steps run as their own
# process. The first hide in each shell works on its own copy of $STUB_DIR and the links, so a
# hide in a subshell can't delete the parent's sentinels and let it reach the real command.
# e.g. hide fzf
hide() {
    local dir name dirs
    # BASH_SUBSHELL tells a subshell from the shell that set _HIDE_SHELL; bash 3.2 has no BASHPID
    if [ "${_HIDE_SHELL-}" != "$BASH_SUBSHELL" ]; then
        _HIDE_SHELL="$BASH_SUBSHELL"
        dir="$(mktemp -d "$SANDBOX/hide.XXXXXX")"
        cp -Rp "$STUB_DIR" "$dir/stubs"
        _HIDE_LINKS="$dir/path"
        mkdir "$_HIDE_LINKS"
        IFS=: read -ra dirs <<< "$PATH"
        # An earlier hide's links dir links on, so what it hid stays hidden
        for dir in ${dirs[@]+"${dirs[@]}"}; do
            [ "$dir" != "$STUB_DIR" ] && [ -d "$dir" ] || continue
            # ln skips a name an earlier dir already linked, as PATH would, and carries on
            ln -s "$dir"/* "$_HIDE_LINKS"/ 2> /dev/null || true
        done
        STUB_DIR="${_HIDE_LINKS%/path}/stubs"
    fi
    # Also when a later hide in this shell finds a PATH a script changed
    export PATH="$STUB_DIR:$_HIDE_LINKS"
    for name in "$@"; do
        rm -f "$_HIDE_LINKS/$name" "$STUB_DIR/$name"
        [ "$name" != brew ] || export DOTFILES_NO_LOAD_BREW=1
    done
}

# Skip the test: print why, and exit 77, which tests/run.sh reports as SKIP. Use it when a tool
# the test needs isn't installed. skip_rest prints why and carries on, and the test then exits 77
# unless it failed.
# e.g. command -v jq &> /dev/null || skip "jq isn't installed"
skip() {
    echo "SKIP: $1"
    exit 77
}

skip_rest() {
    echo "SKIP: $1"
    TEST_SKIPPED=true
}

# Run a command, usually a function the test defines, in a subshell, so what it changes, such as
# the commands it hides or the functions it replaces, stays there. Its failed checks count as the
# test's.
# e.g. subtest firmware_without_jq
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

# Mark the end of the test: its last line. A test that exits 0 without it fails (see _sandbox_exit).
test_done() {
    TEST_DONE=true
}

# Stand in for GitHub for the tmux plugins in tmux/plugins.lock: give each a local repo with two
# commits, under $SANDBOX/remotes, which a git url rewrite makes https://github.com/<repo>, and pin
# each to its first commit, not HEAD, in a lock file the tmux step reads through
# DOTFILES_TMUX_PLUGINS_LOCK. Sets FAKE_PLUGIN_REMOTES to the remotes' dir.
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
            git -C "$remote" -c user.name=test -c user.email=test@example.com commit -qm "$n"
            [ "$n" -eq 2 ] || sha="$(git -C "$remote" rev-parse HEAD)"
        done
        echo "$repo $sha" >> "$DOTFILES_TMUX_PLUGINS_LOCK"
    done < <(awk '!/^#/ && NF' "$REPO_DIR/tmux/plugins.lock")
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$FAKE_PLUGIN_REMOTES/.insteadOf"
    export GIT_CONFIG_VALUE_0=https://github.com/
}

# Source lib/common.sh or a step script, given relative to the repo, so the test can call its
# functions. Remaining arguments become the script's "$@". A step runs main only when run
# directly, so this runs none of it. A step's set -euo pipefail carries over to the test.
# A syntax error in the script or in lib/common.sh, which steps source, ends the test with status
# 2: sourced, it would end it with 0, since bash 3.2 gives the EXIT trap a $? of 0.
# e.g. load_script vim/install.sh
load_script() {
    local script="$REPO_DIR/$1" f
    shift
    for f in "$script" "$REPO_DIR/lib/common.sh"; do
        if ! "$BASH" -n "$f"; then
            echo "Syntax error in $f" >&2
            exit 2
        fi
    done
    # lib/common.sh defines its default main only when none exists, so a step loaded earlier with
    # its own main would hide a later step's default one. Reloading lib/common.sh alone keeps main.
    [ "$script" == "$REPO_DIR/lib/common.sh" ] || unset -f main
    # shellcheck source=/dev/null
    source "$script" "$@"
    _stubs_first
}

# Copy a root ntfy hook (ubuntu/smartd-notify.sh or ubuntu/ups-notify.sh) to <dest>, with its
# NTFY_URL_FILE and NTFY_LIB constants pointed at <url-file> and <lib>. The hooks hard-code the
# installed paths, since root runs them, so no variable may redirect them.
# e.g. ntfy_hook_copy ubuntu/smartd-notify.sh "$SANDBOX/ntfy-url" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$SANDBOX/hook"
ntfy_hook_copy() {
    sed -e "s|^NTFY_URL_FILE=.*|NTFY_URL_FILE=\"$2\"|" -e "s|^NTFY_LIB=.*|NTFY_LIB=\"$3\"|" \
        "$REPO_DIR/$1" > "$4"
    if ! grep -qxF "NTFY_URL_FILE=\"$2\"" "$4" || ! grep -qxF "NTFY_LIB=\"$3\"" "$4"; then
        fail "$1 has no NTFY_URL_FILE= or NTFY_LIB= line to point at the sandbox"
    fi
}

# Run a command in a subshell with errexit on, as a step's own `set -e` would run it, and keep
# its combined stdout and stderr in $RUN_OUTPUT and its exit status in $RUN_STATUS. It always
# succeeds, so a test under set -e carries on.
# e.g. run bash "$REPO_DIR/setup.sh" vim
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

# Record a failed check, naming the test line that made it
# e.g. [ -x "$HOME/.local/bin/git-wt" ] || fail "git-wt isn't executable"
fail() {
    local i=1
    TEST_FAILURES=$((TEST_FAILURES + 1))
    while [ "${BASH_SOURCE[$i]:-}" == "${BASH_SOURCE[0]}" ]; do
        i=$((i + 1))
    done
    echo "FAIL ${BASH_SOURCE[$i]##*/}:${BASH_LINENO[$((i - 1))]}: $1" >&2
}

# Print text indented under a failure, if there is any. Only builtins, so it works after hide.
_show() {
    local line
    [ -n "$1" ] || return 0
    while IFS= read -r line; do
        printf '    %s\n' "$line" >&2
    done <<< "$1"
}

# e.g. assert_eq "ok" "$state" "vimrc status"
assert_eq() {
    [ "$1" == "$2" ] && return 0
    fail "${3:-values differ}: expected '$1', got '$2'"
    return 0
}

# Check that a string contains, or doesn't contain, a fixed string
# e.g. assert_contains "$RUN_OUTPUT" "Copied"
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

# Check that a file has, or doesn't have, a line containing a fixed string
# e.g. assert_file_contains "$STUB_LOG" "systemctl --user restart t3-code"
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

# Run a command with run and check its exit status. $RUN_OUTPUT is left for further checks.
# e.g. assert_exit 3 bash "$REPO_DIR/vim/install.sh" --status
assert_exit() {
    local expected="$1"
    shift
    run "$@"
    [ "$RUN_STATUS" == "$expected" ] && return 0
    fail "'$*' exited $RUN_STATUS, not $expected. Its output:"
    _show "$RUN_OUTPUT"
    return 0
}
