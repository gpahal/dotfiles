#!/bin/bash
set -euo pipefail

# interrogate's run-reviewer.sh and code-review's materialize-head.sh.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
REAL_SLEEP="$(command -v sleep)"
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
export REVIEWER_SLEEP=600 REVIEWER_TIMEOUT=900

# Each sleep, the reviewer's and the watchdog's, records its pid, so the checks see only this test's
export SLEEPS="$SANDBOX/sleeps"
printf '%s\n' '#!/bin/bash' 'echo "$$" >> "$SLEEPS"' "exec $(printf '%q' "$REAL_SLEEP") \"\$@\"" > "$STUB_DIR/sleep"
chmod +x "$STUB_DIR/sleep"

# A zombie isn't running, though kill -0 finds it, and a pid that isn't sleep's was reused
running_sleeps() {
    local pid
    [ -e "$SLEEPS" ] || return 0
    while read -r pid; do
        case "$(ps -o stat= -p "$pid" 2> /dev/null)" in
            '' | Z*) ;;
            *) [ "$(basename "$(ps -o comm= -p "$pid" 2> /dev/null)")" != sleep ] || echo "$pid" ;;
        esac
    done < "$SLEEPS"
}

both_sleeps_started() {
    [ "$(running_sleeps | wc -l | tr -d ' ')" -ge 2 ]
}

no_sleeps_left() {
    [ -z "$(running_sleeps)" ]
}

# The reviewer runs in a process group of its own, which the test runner's signals miss
RUNNER_PID=""
# shellcheck disable=SC2046 # a list of pids
trap 'status=$?; set +e; [ -z "$RUNNER_PID" ] || kill "$RUNNER_PID"; kill $(running_sleeps) 2> /dev/null; (exit "$status"); _sandbox_exit' EXIT

stub claude 'sleep "$REVIEWER_SLEEP"'
(cd "$REPO" && exec bash "$RUNNER" claude model high "$PROMPT" "$OUT") > /dev/null 2>&1 &
RUNNER_PID=$!
wait_for both_sleeps_started || fail "the reviewer and the watchdog didn't both start"
kill -TERM "$RUNNER_PID"
status=0
wait "$RUNNER_PID" || status=$?
RUNNER_PID=""
assert_eq 143 "$status" "exit status after SIGTERM"
wait_for no_sleeps_left || fail "processes left running after SIGTERM: $(running_sleeps | tr '\n' ' ')"

stub claude 'echo "No findings."'
cd "$REPO"
assert_exit 0 bash "$RUNNER" claude model high "$PROMPT" "$OUT"
assert_file_contains "$OUT" "No findings."
wait_for no_sleeps_left || fail "the watchdog outlived a finished review"

stub claude 'echo "boom" >&2; exit 5'
assert_exit 1 bash "$RUNNER" claude model high "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "claude exited with status 5"
[ ! -e "$OUT" ] || fail "a failed review left an answer"

stub claude 'bash -c '\''sleep "$REVIEWER_SLEEP" & wait'\'' & wait'
REVIEWER_TIMEOUT=1 assert_exit 1 bash "$RUNNER" claude model low "$PROMPT" "$OUT"
assert_contains "$RUN_OUTPUT" "claude exited with status 143 (a status of 143 means it ran past 1s)"
[ ! -e "$OUT" ] || fail "a timed-out review left an answer"
wait_for no_sleeps_left || fail "the timed-out reviewer is still running"

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
