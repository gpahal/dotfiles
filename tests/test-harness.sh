#!/bin/bash
set -euo pipefail

# Checks tests/lib.sh itself: the sandbox, stubs, sentinels, hide, load_script, run, and that
# failures, skips, and cleanup reach the exit status. Then checks that tests/run.sh reports them.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

real_home="$HOME"
export BASH_ENV=/nonexistent MISE_CONFIG_DIR=/nonexistent MISE_STATE_DIR=/nonexistent
setup_sandbox

# The sandbox
[ "$HOME" != "$real_home" ] || fail "HOME is still the real one"
assert_eq "$SANDBOX/home" "$HOME" "HOME"
assert_eq "$SANDBOX/tmux" "$TMUX_TMPDIR" "TMUX_TMPDIR"
assert_eq "$SANDBOX/worktrees" "$WORKTREES_DIR" "WORKTREES_DIR"
assert_eq "" "$(compgen -e | grep '^XDG_' || true)" "XDG_* variables"
assert_eq "$STUB_DIR" "${PATH%%:*}" "first PATH entry"
[ ! -t 0 ] || fail "stdin is a terminal"
assert_eq "" "${BASH_ENV-}${MISE_CONFIG_DIR-}${MISE_STATE_DIR-}" "BASH_ENV and MISE_* variables"
for cmd in nmcli apt-config journalctl; do
    assert_eq "$STUB_DIR/$cmd" "$(command -v "$cmd")" "$cmd sentinel"
done

# Stubs log their arguments and run their body
stub greet 'echo "hi $1"; exit 3'
assert_exit 3 greet there "two words"
assert_eq "hi there" "$RUN_OUTPUT" "stub output"
assert_file_contains "$STUB_LOG" "greet there two words"
stub quiet
assert_exit 0 quiet
assert_eq "" "$RUN_OUTPUT" "bodiless stub output"
assert_file_contains "$STUB_LOG" "quiet"

# run turns on errexit, as a step's own set -e would
stops_early() {
    false
    echo "carried on"
}
assert_exit 1 stops_early
assert_not_contains "$RUN_OUTPUT" "carried on"

# Sourcing a step defines its functions without running main, and keeps stubs first on PATH
load_script vim/install.sh
[ "$(type -t main)" == function ] || fail "vim/install.sh didn't define main"
assert_eq "" "$(/bin/ls -A "$HOME")" "files in HOME after sourcing a step"
assert_eq "$STUB_DIR" "${PATH%%:*}" "first PATH entry after load_script"
assert_exit 1 confirm "Proceed?"

# Running a step writes into the sandbox, and the status report sees it
assert_exit 0 "$BASH" "$REPO_DIR/vim/install.sh"
assert_file_contains "$HOME/.vimrc" "$(head -1 "$REPO_DIR/vim/vimrc")"
assert_exit 0 "$BASH" "$REPO_DIR/vim/install.sh" --status
assert_contains "$RUN_OUTPUT" "ok"

# A failed assertion fails a test that otherwise succeeds, and the sandbox is removed on exit
inner_test() {
    printf '%s\n' "source '$TESTS_DIR/lib.sh'" 'setup_sandbox' 'echo "$SANDBOX"' "$1" test_done
}
run "$BASH" -c "$(inner_test 'assert_eq a b')"
assert_eq 1 "$RUN_STATUS" "exit status of a test with a failed assertion"
assert_contains "$RUN_OUTPUT" ": values differ: expected 'a', got 'b'"
inner_sandbox="$(printf '%s\n' "$RUN_OUTPUT" | head -1)"
[ ! -e "$inner_sandbox" ] || fail "sandbox $inner_sandbox wasn't removed"
run "$BASH" -c "$(inner_test 'assert_eq a a')"
assert_eq 0 "$RUN_STATUS" "exit status of a passing test"
run "$BASH" -c "$(inner_test 'exit 4')"
assert_eq 4 "$RUN_STATUS" "exit status of a test that exits early"
# A test that set -u stops fails, though bash 3.2 gives the EXIT trap a $? of 0 then
run "$BASH" -c "$(inner_test 'set -euo pipefail; echo "$unset_var"; echo "carried on"')"
assert_eq 1 "$RUN_STATUS" "exit status of a test that used an unset variable"
assert_not_contains "$RUN_OUTPUT" "carried on"

# A sentinel stands in for each command that changes the machine or uses the network. Running
# one fails the test, even under || true, and stub replaces it.
for cmd in brew apt-get systemctl defaults curl sudo mise claude codex t3 uv bun pnpm; do
    [ -x "$STUB_DIR/$cmd" ] || fail "no sentinel or stub for $cmd"
done
run "$BASH" -c "$(inner_test 'mise install || true; codex --version || true')"
assert_eq 1 "$RUN_STATUS" "exit status of a test that ran unstubbed tools"
assert_contains "$RUN_OUTPUT" "Commands ran that the test didn't stub:
    mise install
    codex --version"
run "$BASH" -c "$(inner_test 'brew install foo || true; curl -fsSL https://example.com || true')"
assert_eq 1 "$RUN_STATUS" "exit status of a test that ran sentinels"
assert_contains "$RUN_OUTPUT" "unstubbed command: brew"
assert_contains "$RUN_OUTPUT" "Commands ran that the test didn't stub:
    brew install foo
    curl -fsSL https://example.com"
run "$BASH" -c "$(inner_test 'set -e; brew install foo; echo "carried on"')"
assert_eq 127 "$RUN_STATUS" "exit status of a test that ran a sentinel under set -e"
assert_not_contains "$RUN_OUTPUT" "carried on"
run "$BASH" -c "$(inner_test 'stub brew; brew install foo')"
assert_eq 0 "$RUN_STATUS" "exit status of a test that stubbed brew"
assert_not_contains "$RUN_OUTPUT" "unstubbed"

# hide makes a command missing, sentinel or not, and keeps the rest of PATH and later stubs
run "$BASH" -c "$(inner_test 'hide brew git; command -v brew || echo "no brew"; command -v git || echo "no git"
command -v sed > /dev/null && echo "sed found"; stub git; command -v git')"
assert_eq 0 "$RUN_STATUS" "exit status of a test that hid commands"
assert_contains "$RUN_OUTPUT" "no brew"
assert_contains "$RUN_OUTPUT" "no git"
assert_contains "$RUN_OUTPUT" "sed found"
assert_contains "$RUN_OUTPUT" "/stubs/git"
# Loading lib/common.sh after hide brew doesn't put a real Homebrew back on PATH
run "$BASH" -c "$(inner_test 'hide brew; load_script lib/common.sh; command -v brew || echo "no brew"')"
assert_contains "$RUN_OUTPUT" "no brew"
# nor does a script run as its own process
run "$BASH" -c "$(inner_test 'hide brew; "$BASH" -c "source \"\$REPO_DIR/lib/common.sh\"; command -v brew || echo \"no brew\""')"
assert_contains "$RUN_OUTPUT" "no brew"
# hide in a subshell leaves the parent's sentinels and commands alone, before and after the
# parent's own hide
run "$BASH" -c "$(inner_test '( hide curl sed ); [ "$(command -v curl)" != "$STUB_DIR/curl" ] || echo "curl sentinel kept"
command -v sed > /dev/null && echo "sed found"
hide git; ( hide sed ); command -v sed > /dev/null && echo "sed found after hide"')"
assert_eq 0 "$RUN_STATUS" "exit status of a test that hid commands in a subshell"
assert_contains "$RUN_OUTPUT" "curl sentinel kept"
assert_contains "$RUN_OUTPUT" "sed found"
assert_contains "$RUN_OUTPUT" "sed found after hide"

# skip exits 77, skip_rest makes a passing test exit 77, and a failure beats either
run "$BASH" -c "$(inner_test 'skip "jq is missing"; echo "carried on"')"
assert_eq 77 "$RUN_STATUS" "exit status of a skipped test"
assert_contains "$RUN_OUTPUT" "SKIP: jq is missing"
assert_not_contains "$RUN_OUTPUT" "carried on"
run "$BASH" -c "$(inner_test 'skip_rest "the tmux part"; echo "carried on"')"
assert_eq 77 "$RUN_STATUS" "exit status of a partly skipped test"
assert_contains "$RUN_OUTPUT" "carried on"
run "$BASH" -c "$(inner_test 'assert_eq a b; skip "jq is missing"')"
assert_eq 1 "$RUN_STATUS" "exit status of a test that failed, then skipped"
run "$BASH" -c "$(inner_test 'skip_rest "the tmux part"; assert_eq a b')"
assert_eq 1 "$RUN_STATUS" "exit status of a partly skipped test that failed"

# Git variables from the environment, such as a hook's GIT_DIR, can't point git at the real repo
# or config
run "$BASH" -c "export GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent \
GIT_CONFIG_GLOBAL=/nonexistent GIT_CONFIG_SYSTEM=/nonexistent GIT_CEILING_DIRECTORIES=/nonexistent
$(inner_test 'env | grep -E "^GIT_(DIR|WORK_TREE|INDEX_FILE|CONFIG_|CEILING_|ALLOW_)" | sort')"
assert_eq 0 "$RUN_STATUS" "exit status of a test with git variables set"
assert_eq "GIT_ALLOW_PROTOCOL=file
GIT_CONFIG_NOSYSTEM=1" "$(printf '%s\n' "$RUN_OUTPUT" | sed 1d)" "git variables in the sandbox"
# Config passed through the environment, as `git -c` and GIT_CONFIG_COUNT pass it to hooks and
# child processes, doesn't reach the test's git
run env GIT_CONFIG_PARAMETERS="'user.name'='poison'" GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.email \
    GIT_CONFIG_VALUE_0=poison@example.com GIT_CONFIG_KEY_1=url./nonexistent.insteadOf \
    GIT_CONFIG_VALUE_1="$SANDBOX" "$BASH" -c "$(inner_test 'env | grep -E "^GIT_CONFIG_(PARAMETERS|COUNT|KEY|VALUE)" || true
git config --get user.name || echo "no user.name"
git config --get user.email || echo "no user.email"
git config --get-regexp "^url\." || echo "no url rewrite"')"
assert_eq 0 "$RUN_STATUS" "exit status of a test with inherited git config"
assert_eq "no user.name
no user.email
no url rewrite" "$(printf '%s\n' "$RUN_OUTPUT" | sed 1d)" "inherited git config in the sandbox"
# Git reaches only local repos, so no test fetches from the network
git -C "$SANDBOX" init -q local-repo
assert_exit 0 git ls-remote "$SANDBOX/local-repo"
assert_exit 128 git ls-remote https://github.com/tmux-plugins/tpm
assert_contains "$RUN_OUTPUT" "transport 'https' not allowed"
assert_exit 128 git ls-remote ssh://git@github.com/tmux-plugins/tpm
assert_contains "$RUN_OUTPUT" "transport 'ssh' not allowed"

# load_script fails on a script with a syntax error. Sourced, the error would end the test with
# status 0, since bash 3.2 gives the EXIT trap a $? of 0.
mkdir -p "$SANDBOX/bad/lib"
cp "$REPO_DIR/lib/common.sh" "$SANDBOX/bad/lib/"
printf '%s\n' 'f() {' '    echo hi' > "$SANDBOX/bad/broken.sh"
run "$BASH" -c "$(inner_test "REPO_DIR='$SANDBOX/bad'; load_script broken.sh")"
assert_eq 2 "$RUN_STATUS" "exit status of a test that loaded a script with a syntax error"
assert_contains "$RUN_OUTPUT" "Syntax error in $SANDBOX/bad/broken.sh"

# run.sh, run on a copy of tests/ with tests of its own: it fails a test with a syntax error, a
# test that runs past the timeout, and any script in the repo with a syntax error, even one no
# test sources
fake="$SANDBOX/repo"
mkdir -p "$fake/tests" "$fake/lib"
cp "$TESTS_DIR/run.sh" "$TESTS_DIR/lib.sh" "$fake/tests/"
printf '%s\n' '#!/bin/bash' 'echo "$SECONDS"' > "$fake/tests/test-ok.sh"
printf '%s\n' '#!/bin/bash' 'source "$(dirname "$0")/lib.sh"' 'setup_sandbox' 'if then' > "$fake/tests/test-syntax.sh"
printf '%s\n' '#!/bin/bash' 'sleep 30 & wait' > "$fake/tests/test-hangs.sh"
printf '%s\n' '#!/bin/bash' 'echo "SKIP: no jq"' 'exit 77' > "$fake/tests/test-skips.sh"
# CI sets TEST_FAIL_ON_SKIP, which these runs leave out until they check it
run env -u TEST_FAIL_ON_SKIP TEST_TIMEOUT=2 "$BASH" "$fake/tests/run.sh" ok syntax hangs skips
assert_eq 1 "$RUN_STATUS" "run.sh's exit status with failing tests"
assert_contains "$RUN_OUTPUT" "PASS  test-ok.sh"
assert_contains "$RUN_OUTPUT" "FAIL  test-syntax.sh"
assert_contains "$RUN_OUTPUT" "FAIL  test-hangs.sh"
assert_contains "$RUN_OUTPUT" "took longer than 2s"
assert_contains "$RUN_OUTPUT" "SKIP  test-skips.sh
    SKIP: no jq"
assert_contains "$RUN_OUTPUT" "1 passed, 2 failed, 1 skipped"
# A skip alone passes the run, unless TEST_FAIL_ON_SKIP=1
run env -u TEST_FAIL_ON_SKIP "$BASH" "$fake/tests/run.sh" ok skips
assert_eq 0 "$RUN_STATUS" "run.sh's exit status with a skipped test"
run env TEST_FAIL_ON_SKIP=1 "$BASH" "$fake/tests/run.sh" ok skips
assert_eq 1 "$RUN_STATUS" "run.sh's exit status with a skipped test and TEST_FAIL_ON_SKIP=1"
assert_contains "$RUN_OUTPUT" "FAIL  test-skips.sh"
assert_contains "$RUN_OUTPUT" "1 passed, 1 failed, 0 skipped"
[ "$SECONDS" -lt 25 ] || fail "run.sh waited for the hanging test's sleep"
# A test's own "# timeout:" line raises its limit
printf '%s\n' '#!/bin/bash' '# timeout: 8' 'sleep 3' > "$fake/tests/test-slow.sh"
run env TEST_TIMEOUT=1 "$BASH" "$fake/tests/run.sh" slow
assert_contains "$RUN_OUTPUT" "PASS  test-slow.sh"
printf '%s\n' 'f() {' > "$fake/lib/broken.sh"
run "$BASH" "$fake/tests/run.sh" ok
assert_eq 1 "$RUN_STATUS" "run.sh's exit status with a broken script"
assert_contains "$RUN_OUTPUT" "FAIL  lib/broken.sh"
assert_contains "$RUN_OUTPUT" "1 script(s) with a syntax error"
# In a git checkout it checks the files git lists, untracked ones included, but not ignored ones
# such as worktrees under .scratch/
git -C "$fake" init -q
echo .scratch/ > "$fake/.gitignore"
mkdir -p "$fake/.scratch/wt"
printf '%s\n' 'f() {' > "$fake/.scratch/wt/broken.sh"
run "$BASH" "$fake/tests/run.sh" ok
assert_contains "$RUN_OUTPUT" "FAIL  lib/broken.sh"
assert_not_contains "$RUN_OUTPUT" ".scratch"
rm "$fake/lib/broken.sh"
run "$BASH" "$fake/tests/run.sh" ok
assert_eq 0 "$RUN_STATUS" "run.sh's exit status with only an ignored broken script"

# A test run by a relative path starts again by its absolute path, with its arguments, so
# step_args can find a loaded step's path after the test cd's into its sandbox
# shellcheck disable=SC2016 # expanded by the test
printf '%s\n' '#!/bin/bash' 'source "$(dirname "$0")/lib.sh"' \
    'echo "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]} $#: $*"' > "$fake/tests/test-path.sh"
run sh -c 'cd "$1" && "$2" tests/test-path.sh a "b c"' sh "$fake" "$BASH"
assert_eq "$fake/tests/test-path.sh 2: a b c" "$RUN_OUTPUT" "a test run by a relative path"
rm "$fake/tests/test-path.sh"

# run.sh gives each test a new HOME and a short TMUX_TMPDIR in its own temp dir, and unsets XDG_*,
# DOTFILES_*, and TMUX, so a test that forgets setup_sandbox still writes nothing outside it. The
# test records what it got in $SANDBOX/env.
printf '%s\n' '#!/bin/bash' "printf '%s\\n' \"\$HOME\" \"\$TMUX_TMPDIR\" >> '$SANDBOX/env'" \
    '! env | grep -E "^(XDG_|DOTFILES_|TMUX=)" || exit 1' \
    '[ -d "$HOME" ] && [ -d "$TMUX_TMPDIR" ] || { echo "missing dirs"; exit 1; }' \
    '[ ! -e "$HOME/marker" ] || { echo "HOME reused"; exit 1; }' 'touch "$HOME/marker"' \
    > "$fake/tests/test-env.sh"
run env XDG_CONFIG_HOME="$HOME/.config" DOTFILES_ASSUME_YES=1 TMUX=/tmp/tmux-0/default,1,0 \
    "$BASH" "$fake/tests/run.sh" env env
assert_eq 0 "$RUN_STATUS" "run.sh's exit status with the environment test"
assert_contains "$RUN_OUTPUT" "2 passed, 0 failed, 0 skipped"
backstop_home="$(head -1 "$SANDBOX/env")"
backstop_tmux="$(sed -n 2p "$SANDBOX/env")"
case "$backstop_home" in
    /tmp/dotfiles-run.*/home | /private/tmp/dotfiles-run.*/home) ;;
    *) fail "run.sh's HOME for a test is $backstop_home" ;;
esac
assert_eq "${backstop_home%/home}/tmux" "$backstop_tmux" "run.sh's TMUX_TMPDIR for a test"
[ "${#backstop_tmux}" -le 40 ] || fail "run.sh's TMUX_TMPDIR is too long for tmux: $backstop_tmux"
[ ! -e "${backstop_home%/home}" ] || fail "run.sh left ${backstop_home%/home} behind"

# TERM, or Ctrl-C, stops run.sh and the test it's running, with what the test started, and
# removes run.sh's temp dir
printf '%s\n' '#!/bin/bash' "echo \"\$HOME\" > '$SANDBOX/sleeper-home'" 'sleep 30 &' \
    "echo \"\$!\" > '$SANDBOX/sleeper.pid'" 'wait' > "$fake/tests/test-sleeps.sh"
"$BASH" "$fake/tests/run.sh" sleeps > /dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do
    [ ! -s "$SANDBOX/sleeper.pid" ] || break
    sleep 0.1
done
kill -TERM "$runner"
runner_status=0
# The braces discard bash's "Terminated" notice
{ wait "$runner"; } 2>/dev/null || runner_status=$?
[ "$runner_status" -ne 0 ] || fail "run.sh exited 0 after TERM"
sleeper="$(cat "$SANDBOX/sleeper.pid" 2>/dev/null || true)"
if [ -z "$sleeper" ]; then
    fail "the sleeping test didn't start"
else
    # Up to 5 s: on a loaded machine the kill can take more than 2
    for _ in $(seq 1 50); do
        kill -0 "$sleeper" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$sleeper" 2>/dev/null; then
        fail "the test's sleep outlived run.sh after TERM"
        kill "$sleeper" 2>/dev/null || true
    fi
    sleeper_home="$(cat "$SANDBOX/sleeper-home")"
    [ ! -e "${sleeper_home%/home}" ] || fail "run.sh left ${sleeper_home%/home} behind after TERM"
fi
test_done
