#!/bin/bash
set -euo pipefail
# serial

# interrogate's run-reviewer.sh stops the reviewer and its watchdog when cancelled, reports the
# reviewer's status and exits 1 on failure, refuses an out-file in the prompt's directory or the
# repo, and ignores CDPATH. A stub claude stands in for the reviewer.
# code-review's materialize-head.sh puts a reviewed head where that reviewer can read it.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# The sandbox's pkill and pgrep are sentinels. This test's own only find and stop the sleeps it
# started.
PKILL="$(command -v pkill)" PGREP="$(command -v pgrep)"
setup_sandbox

RUNNER="$REPO_DIR/ai_tools/skills/engineering/interrogate/scripts/run-reviewer.sh"
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
# The prompt and the answers each get their own directory, as the interrogate skill sets them up
PROMPT="$SANDBOX/prompts/prompt.md"
mkdir -p "$SANDBOX/prompts"
echo "Review this." > "$PROMPT"
mkdir -p "$SANDBOX/answers"
OUT="$SANDBOX/answers/answer.md"

# Sleep lengths only this test uses, so pgrep finds this run's processes and no one else's
export REVIEWER_SLEEP="7$$" REVIEWER_TIMEOUT="8$$"
# OrbStack's amd64 translation exposes both the executable path and argv[0] in the command line.
SLEEP_PATTERN="^([^ ]*/)?sleep (sleep )?($REVIEWER_SLEEP|$REVIEWER_TIMEOUT)\$"

# Print the PIDs of any sleep this test started, the reviewer's or the watchdog's
leftover_sleeps() {
    "$PGREP" -f "$SLEEP_PATTERN" || true
}

# Wait up to 10 seconds for a command to succeed
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

# The runner and the reviewer run in their own process groups, which the signal tests/run.sh
# sends on a timeout or Ctrl-C doesn't reach, and the sleeps would run for days. The runner stops
# its reviewer when it's stopped, and pkill gets any sleep left.
RUNNER_PID=""
on_exit '[ -z "$RUNNER_PID" ] || kill -- "-$RUNNER_PID" 2> /dev/null'
on_exit '"$PKILL" -f "$SLEEP_PATTERN"'

# Start the runner with a reviewer that sleeps, send it a signal, and check its exit status and
# that nothing it started lives on
check_signal() {
    local signal="$1" expected="$2" status=0
    stub claude 'sleep "$REVIEWER_SLEEP"'
    # Job control keeps SIGINT deliverable: without it, a background job ignores SIGINT
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

# A finished review keeps its answer and exits 0, and stops the watchdog
stub claude 'echo "No findings."'
cd "$REPO"
assert_exit 0 bash "$RUNNER" claude model high "$PROMPT" "$OUT"
assert_file_contains "$OUT" "No findings."
wait_for no_sleeps_left || fail "the watchdog outlived a finished review"
"$PKILL" -f "$SLEEP_PATTERN" || true

# Even when the review finishes just after the watchdog starts its sleep. A copy of the runner
# that pauses there makes that happen every time.
awk '{ print } /^ *sleep "\$timeout" &$/ { print "/bin/sleep 0.5" }' "$RUNNER" > "$SANDBOX/run-reviewer-paused.sh"
grep -q '^/bin/sleep 0.5$' "$SANDBOX/run-reviewer-paused.sh" || fail "the paused runner has no pause"
assert_exit 0 bash "$SANDBOX/run-reviewer-paused.sh" claude model high "$PROMPT" "$OUT"
wait_for no_sleeps_left || fail "the watchdog's sleep outlived a review that finished as it started"
"$PKILL" -f "$SLEEP_PATTERN" || true

# A failed review still exits 1 and names the reviewer's status
stub claude 'echo "boom" >&2; exit 5'
assert_exit 1 bash "$RUNNER" claude model high "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "claude exited with status 5"
[ ! -e "$OUT" ] || fail "a failed review left an answer"

# A review that runs past REVIEWER_TIMEOUT stops its descendants too. The watchdog is the same
# for either family.
stub claude 'bash -c '\''sleep "$REVIEWER_SLEEP" & wait'\'' & wait'
REVIEWER_TIMEOUT=1 assert_exit 1 bash "$RUNNER" claude model low "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "claude exited with status 143 (a status of 143 means it ran past 1s)"
[ ! -e "$OUT" ] || fail "a timed-out review left an answer"
wait_for no_sleeps_left || fail "the timed-out reviewer is still running"
"$PKILL" -f "$SLEEP_PATTERN" || true

# The codex branch runs codex exec read-only from the repo root, with the prompt on stdin, and
# keeps the answer it writes to --output-last-message
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

# A codex that fails shows its log; one that writes no answer fails too
stub codex 'echo "codex broke" >&2; exit 3'
assert_exit 1 bash "$RUNNER" codex model high "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "codex exited with status 3"
assert_contains "$RUN_OUTPUT" "codex broke"
stub codex 'cat > /dev/null'
assert_exit 1 bash "$RUNNER" codex model high "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "codex reviewer wrote no answer"

# An out-file in the prompt's directory, or below it, is refused before any reviewer starts,
# since the other reviewer could read the answer there
stub claude 'echo "No findings."'
: > "$STUB_LOG"
mkdir -p "$SANDBOX/prompts/sub"
for out in "$SANDBOX/prompts/answer.md" "$SANDBOX/prompts/sub/answer.md"; do
    assert_exit 2 bash "$RUNNER" claude model high "$PROMPT" "$out"
    assert_contains "$RUN_OUTPUT" "is inside the prompt file's directory"
done
assert_eq "" "$(cat "$STUB_LOG")" "the reviewers started for a refused out-file"
# A sibling whose name starts with the prompt directory's is fine
mkdir -p "$SANDBOX/prompts-answers"
assert_exit 0 bash "$RUNNER" claude model high "$PROMPT" "$SANDBOX/prompts-answers/answer.md"

# An out-file under the repo root is refused too, since both reviewers can read the repo
mkdir -p "$REPO/ans"
: > "$STUB_LOG"
assert_exit 2 bash "$RUNNER" claude model high "$PROMPT" "$REPO/ans/answer.md"
assert_contains "$RUN_OUTPUT" "is inside the repo under review"
assert_eq "" "$(cat "$STUB_LOG")" "the reviewers started for an out-file in the repo"

# A CDPATH with a dir of the same name doesn't redirect a relative prompt or out-file path. The
# decoy is outside the repo, so a redirected out-file would be accepted rather than refused.
mkdir -p "$REPO/rel" "$SANDBOX/decoy/rel" "$SANDBOX/decoy/ans"
echo "Review this." > "$REPO/rel/prompt.md"
: > "$STUB_LOG"
CDPATH="$SANDBOX/decoy" assert_exit 0 bash "$RUNNER" claude model high rel/prompt.md "$OUT"
assert_file_contains "$STUB_LOG" "--add-dir $(pwd -P)/rel "
CDPATH="$SANDBOX/decoy" assert_exit 2 bash "$RUNNER" claude model high rel/prompt.md ans/answer.md
assert_contains "$RUN_OUTPUT" "'$(pwd)/ans/answer.md' is inside the repo under review"

# code-review's materialize-head.sh writes a commit's tracked files, or the staged files, under the
# review's temp dir, so a reviewer reads the reviewed head rather than the working tree. The
# runner's --add-dir, the prompt file's directory, covers them.
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
# The working tree differs from both commits
echo "working tree" > "sub dir/a b.txt"
echo untracked > untracked.txt

review_tmp() {
    rm -rf "$SANDBOX/review tmp"
    mkdir "$SANDBOX/review tmp"
}

# A commit, from a subdirectory: its files, not the working tree's
review_tmp
cd "sub dir"
assert_exit 0 bash "$MATERIALIZE" "$SANDBOX/review tmp" "$OLD"
assert_eq "$SANDBOX/review tmp/head" "$RUN_OUTPUT" "the printed head dir"
assert_eq old "$(cat "$SANDBOX/review tmp/head/sub dir/a b.txt")" "the old commit's file"
assert_eq kept "$(cat "$SANDBOX/review tmp/head/kept.txt")" "a file the next commit deleted"
[ ! -e "$SANDBOX/review tmp/head/untracked.txt" ] || fail "an untracked file was copied"
assert_eq head "$(/bin/ls -A "$SANDBOX/review tmp")" "what's left in the temp dir"
cd "$HIST"
# A range's head, given as a ref
review_tmp
assert_exit 0 bash "$MATERIALIZE" "$SANDBOX/review tmp" HEAD
assert_eq new "$(cat "$SANDBOX/review tmp/head/sub dir/a b.txt")" "the range head's file"
[ ! -e "$SANDBOX/review tmp/head/kept.txt" ] || fail "a deleted file was copied"
git worktree list | grep -q "review tmp" && fail "it added a worktree"

# The restricted Claude reviewer reads the head through the prompt's directory
echo "Review this." > "$SANDBOX/review tmp/prompt.md"
stub claude '
while [ $# -gt 0 ]; do
    [ "$1" != --add-dir ] || dir="$2"
    shift
done
cat "$dir/head/sub dir/a b.txt"'
assert_exit 0 bash "$RUNNER" claude model high "$SANDBOX/review tmp/prompt.md" "$OUT"
assert_eq new "$(cat "$OUT")" "what the reviewer read"

# A missing commit fails and leaves nothing behind
review_tmp
assert_exit 2 bash "$MATERIALIZE" "$SANDBOX/review tmp" 0123456789abcdef0123456789abcdef01234567
assert_contains "$RUN_OUTPUT" "isn't a commit"
assert_eq "" "$(/bin/ls -A "$SANDBOX/review tmp")" "the temp dir after a missing commit"
# So does one that can't write its temp dir
chmod 500 "$SANDBOX/review tmp"
assert_exit 1 bash "$MATERIALIZE" "$SANDBOX/review tmp" HEAD
chmod 700 "$SANDBOX/review tmp"
assert_eq "" "$(/bin/ls -A "$SANDBOX/review tmp")" "the temp dir after a failed checkout"
# And a checkout that fails partway, after the head dir and the index are written: both go
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
review_tmp
assert_exit 1 bash "$MATERIALIZE" "$SANDBOX/review tmp" HEAD
assert_eq "" "$(/bin/ls -A "$SANDBOX/review tmp")" "the temp dir after a range head's checkout failed partway"
rm "$STUB_DIR/git"
# An existing head dir is left alone
mkdir "$SANDBOX/review tmp/head"
echo mine > "$SANDBOX/review tmp/head/mine.txt"
assert_exit 2 bash "$MATERIALIZE" "$SANDBOX/review tmp" HEAD
assert_eq mine "$(cat "$SANDBOX/review tmp/head/mine.txt")" "an existing head dir's file"

# Staged: the index's version of each added or changed file, not the working tree's
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
