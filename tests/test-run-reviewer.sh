#!/bin/bash
set -euo pipefail
# serial

# interrogate's run-reviewer.sh and code-review's materialize-head.sh.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# The sandbox's pkill and pgrep are sentinels; these only reach this test's sleeps
PKILL="$(command -v pkill)" PGREP="$(command -v pgrep)"
setup_sandbox

RUNNER="$REPO_DIR/ai_tools/skills/engineering/interrogate/scripts/run-reviewer.sh"
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
PROMPT="$SANDBOX/prompts/prompt.md"
mkdir -p "$SANDBOX/prompts"
echo "Review this." > "$PROMPT"
mkdir -p "$SANDBOX/answers"
OUT="$SANDBOX/answers/answer.md"

# Sleep lengths unique to this run, so pgrep finds only its processes
export REVIEWER_SLEEP="7$$" REVIEWER_TIMEOUT="8$$"
# OrbStack's amd64 translation shows both the executable path and argv[0]
SLEEP_PATTERN="^([^ ]*/)?sleep (sleep )?($REVIEWER_SLEEP|$REVIEWER_TIMEOUT)\$"

leftover_sleeps() {
    "$PGREP" -f "$SLEEP_PATTERN" || true
}

wait_for() {
    local i
    for i in $(seq 100); do
        "$@" && return 0
        sleep 0.1
    done
    return 1
}

both_sleeps_started() {
    [ "$(leftover_sleeps | wc -l | tr -d ' ')" -ge 2 ]
}

no_sleeps_left() {
    [ -z "$(leftover_sleeps)" ]
}

# tests/run.sh's signals don't reach the runner's process groups; the sleeps would run for days
RUNNER_PID=""
on_exit '[ -z "$RUNNER_PID" ] || kill -- "-$RUNNER_PID" 2> /dev/null'
on_exit '"$PKILL" -f "$SLEEP_PATTERN"'

check_signal() {
    local signal="$1" expected="$2" status=0
    stub claude 'sleep "$REVIEWER_SLEEP"'
    # A background job ignores SIGINT without job control
    set -m
    (cd "$REPO" && exec bash "$RUNNER" claude model high "$PROMPT" "$OUT") > /dev/null 2>&1 &
    RUNNER_PID=$!
    set +m
    wait_for both_sleeps_started || fail "$signal: the reviewer and the watchdog didn't both start"
    kill -"$signal" "$RUNNER_PID"
    wait "$RUNNER_PID" || status=$?
    RUNNER_PID=""
    assert_eq "$expected" "$status" "exit status after SIG$signal"
    wait_for no_sleeps_left || fail "$signal: processes left running: $(leftover_sleeps | tr '\n' ' ')"
    "$PKILL" -f "$SLEEP_PATTERN" || true
}

check_signal TERM 143
check_signal INT 130

stub claude 'echo "No findings."'
cd "$REPO"
assert_exit 0 bash "$RUNNER" claude model high "$PROMPT" "$OUT"
assert_file_contains "$OUT" "No findings."
wait_for no_sleeps_left || fail "the watchdog outlived a finished review"
"$PKILL" -f "$SLEEP_PATTERN" || true

# A runner paused after the watchdog starts its sleep hits the race every time
awk '{ print } /^ *sleep "\$timeout" &$/ { print "/bin/sleep 0.5" }' "$RUNNER" > "$SANDBOX/run-reviewer-paused.sh"
grep -q '^/bin/sleep 0.5$' "$SANDBOX/run-reviewer-paused.sh" || fail "the paused runner has no pause"
assert_exit 0 bash "$SANDBOX/run-reviewer-paused.sh" claude model high "$PROMPT" "$OUT"
wait_for no_sleeps_left || fail "the watchdog's sleep outlived a review that finished as it started"
"$PKILL" -f "$SLEEP_PATTERN" || true

stub claude 'echo "boom" >&2; exit 5'
assert_exit 1 bash "$RUNNER" claude model high "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "claude exited with status 5"
[ ! -e "$OUT" ] || fail "a failed review left an answer"

stub claude 'bash -c '\''sleep "$REVIEWER_SLEEP" & wait'\'' & wait'
REVIEWER_TIMEOUT=1 assert_exit 1 bash "$RUNNER" claude model low "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "claude exited with status 143 (a status of 143 means it ran past 1s)"
[ ! -e "$OUT" ] || fail "a timed-out review left an answer"
wait_for no_sleeps_left || fail "the timed-out reviewer is still running"
"$PKILL" -f "$SLEEP_PATTERN" || true

stub codex '
while [ $# -gt 0 ]; do
    [ "$1" != --output-last-message ] || answer="$2"
    shift
done
cat > "$answer.stdin"
echo "No findings." > "$answer"'
mkdir -p "$REPO/sub"
cd "$REPO/sub"
assert_exit 0 bash "$RUNNER" codex gpt-test xhigh "$PROMPT" "$OUT"
assert_file_contains "$OUT" "No findings."
assert_file_contains "$STUB_LOG" "codex exec --model gpt-test -c model_reasoning_effort=\"xhigh\" -c approval_policy=\"never\" --ignore-user-config --ignore-rules --sandbox read-only --disable multi_agent --ephemeral --cd $(cd "$REPO" && pwd -P) --output-last-message $OUT -"
assert_eq "Review this." "$(cat "$OUT.stdin")" "the prompt codex read"
cd "$REPO"

stub codex 'echo "codex broke" >&2; exit 3'
assert_exit 1 bash "$RUNNER" codex model high "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "codex exited with status 3"
assert_contains "$RUN_OUTPUT" "codex broke"
stub codex 'cat > /dev/null'
assert_exit 1 bash "$RUNNER" codex model high "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "codex reviewer wrote no answer"

# The other reviewer could read an answer in the prompt's directory
stub claude 'echo "No findings."'
: > "$STUB_LOG"
mkdir -p "$SANDBOX/prompts/sub"
for out in "$SANDBOX/prompts/answer.md" "$SANDBOX/prompts/sub/answer.md"; do
    assert_exit 2 bash "$RUNNER" claude model high "$PROMPT" "$out"
    assert_contains "$RUN_OUTPUT" "is inside the prompt file's directory"
done
assert_eq "" "$(cat "$STUB_LOG")" "the reviewers started for a refused out-file"
mkdir -p "$SANDBOX/prompts-answers"
assert_exit 0 bash "$RUNNER" claude model high "$PROMPT" "$SANDBOX/prompts-answers/answer.md"

mkdir -p "$REPO/ans"
: > "$STUB_LOG"
assert_exit 2 bash "$RUNNER" claude model high "$PROMPT" "$REPO/ans/answer.md"
assert_contains "$RUN_OUTPUT" "is inside the repo under review"
assert_eq "" "$(cat "$STUB_LOG")" "the reviewers started for an out-file in the repo"

# The decoy is outside the repo, so a redirected out-file would be accepted
mkdir -p "$REPO/rel" "$SANDBOX/decoy/rel" "$SANDBOX/decoy/ans"
echo "Review this." > "$REPO/rel/prompt.md"
: > "$STUB_LOG"
CDPATH="$SANDBOX/decoy" assert_exit 0 bash "$RUNNER" claude model high rel/prompt.md "$OUT"
assert_file_contains "$STUB_LOG" "--add-dir $(pwd -P)/rel "
CDPATH="$SANDBOX/decoy" assert_exit 2 bash "$RUNNER" claude model high rel/prompt.md ans/answer.md
assert_contains "$RUN_OUTPUT" "'$(pwd)/ans/answer.md' is inside the repo under review"

MATERIALIZE="$REPO_DIR/ai_tools/skills/engineering/code-review/scripts/materialize-head.sh"
HIST="$SANDBOX/hist repo"
git init -q "$HIST"
cd "$HIST"
git config user.email t@example.com
git config user.name Test
mkdir "sub dir"
echo old > "sub dir/a b.txt"
echo kept > kept.txt
git add -A
git commit -qm one
OLD="$(git rev-parse HEAD)"
echo new > "sub dir/a b.txt"
git rm -q kept.txt
git commit -qam two
echo "working tree" > "sub dir/a b.txt"
echo untracked > untracked.txt

review_tmp() {
    rm -rf "$SANDBOX/review tmp"
    mkdir "$SANDBOX/review tmp"
}

review_tmp
cd "sub dir"
assert_exit 0 bash "$MATERIALIZE" "$SANDBOX/review tmp" "$OLD"
assert_eq "$SANDBOX/review tmp/head" "$RUN_OUTPUT" "the printed head dir"
assert_eq old "$(cat "$SANDBOX/review tmp/head/sub dir/a b.txt")" "the old commit's file"
assert_eq kept "$(cat "$SANDBOX/review tmp/head/kept.txt")" "a file the next commit deleted"
[ ! -e "$SANDBOX/review tmp/head/untracked.txt" ] || fail "an untracked file was copied"
assert_eq head "$(/bin/ls -A "$SANDBOX/review tmp")" "what's left in the temp dir"
cd "$HIST"
review_tmp
assert_exit 0 bash "$MATERIALIZE" "$SANDBOX/review tmp" HEAD
assert_eq new "$(cat "$SANDBOX/review tmp/head/sub dir/a b.txt")" "the range head's file"
[ ! -e "$SANDBOX/review tmp/head/kept.txt" ] || fail "a deleted file was copied"
git worktree list | grep -q "review tmp" && fail "it added a worktree"

echo "Review this." > "$SANDBOX/review tmp/prompt.md"
stub claude '
while [ $# -gt 0 ]; do
    [ "$1" != --add-dir ] || dir="$2"
    shift
done
cat "$dir/head/sub dir/a b.txt"'
assert_exit 0 bash "$RUNNER" claude model high "$SANDBOX/review tmp/prompt.md" "$OUT"
assert_eq new "$(cat "$OUT")" "what the reviewer read"

review_tmp
assert_exit 2 bash "$MATERIALIZE" "$SANDBOX/review tmp" 0123456789abcdef0123456789abcdef01234567
assert_contains "$RUN_OUTPUT" "isn't a commit"
assert_eq "" "$(/bin/ls -A "$SANDBOX/review tmp")" "the temp dir after a missing commit"
chmod 500 "$SANDBOX/review tmp"
assert_exit 1 bash "$MATERIALIZE" "$SANDBOX/review tmp" HEAD
chmod 700 "$SANDBOX/review tmp"
assert_eq "" "$(/bin/ls -A "$SANDBOX/review tmp")" "the temp dir after a failed checkout"
# A checkout failing after the head dir and index are written removes both
real_git="$(command -v git)"
stub git 'if [ "${1:-}" = checkout-index ] || [ "${3:-}" = checkout-index ]; then
    "'"$real_git"'" "$@"
    exit 1
fi
exec "'"$real_git"'" "$@"'
review_tmp
assert_exit 1 bash "$MATERIALIZE" "$SANDBOX/review tmp" "$OLD"
assert_file_contains "$STUB_LOG" "git checkout-index --all --prefix=$SANDBOX/review tmp/head/"
assert_eq "" "$(/bin/ls -A "$SANDBOX/review tmp")" "the temp dir after a checkout that failed partway"
rm "$STUB_DIR/git"
mkdir "$SANDBOX/review tmp/head"
echo mine > "$SANDBOX/review tmp/head/mine.txt"
assert_exit 2 bash "$MATERIALIZE" "$SANDBOX/review tmp" HEAD
assert_eq mine "$(cat "$SANDBOX/review tmp/head/mine.txt")" "an existing head dir's file"

echo staged > "sub dir/a b.txt"
echo "new file" > "new file.txt"
git add "sub dir/a b.txt" "new file.txt"
echo "after staging" > "sub dir/a b.txt"
review_tmp
assert_exit 0 bash "$MATERIALIZE" "$SANDBOX/review tmp" --staged
assert_eq staged "$(cat "$SANDBOX/review tmp/head/sub dir/a b.txt")" "the staged file"
assert_eq "new file" "$(cat "$SANDBOX/review tmp/head/new file.txt")" "a staged new file"
[ ! -e "$SANDBOX/review tmp/head/untracked.txt" ] || fail "staged: an untracked file was copied"
git reset -q

cd "$REPO"
test_done
