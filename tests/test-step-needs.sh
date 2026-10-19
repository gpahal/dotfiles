#!/bin/bash
set -euo pipefail

# STEP_NEEDS: when homebrew fails, run_steps skips the steps that need it, without starting them,
# says why, and counts them as failed, so the summary and its re-run hint name them. A step that
# needs a skipped one is skipped too. A needed step that isn't part of the run doesn't gate, and
# neither does a --status report. Every STEP_NEEDS line in the repo names a real step.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

steps="$SANDBOX/steps"
mkdir -p "$steps"
# fake_step <name> <needs> <body>: a step script that logs its name and arguments, then runs the
# body
fake_step() {
    printf '%s\n' '#!/bin/bash' "STEP_NEEDS=\"$2\"" "echo \"$1\${*:+ \$*}\" >> \"$SANDBOX/ran\"" "$3" \
        > "$steps/$1.sh"
}
# homebrew fails, as it does when its installer can't be downloaded
fake_step homebrew "" 'echo "Couldn'"'"'t download Homebrew'"'"'s installer." >&2; exit 1'
fake_step runtimes homebrew ''
fake_step lazygit "" ''
fake_step skills "runtimes" ''
# shellcheck disable=SC2034 # run_steps reads it
STEPS=(homebrew runtimes lazygit skills)
replace_fn step_script '[ -f "$steps/$1.sh" ] && echo "$steps/$1.sh"'

# homebrew fails: runtimes, which needs it, and skills, which needs runtimes, are skipped and
# listed as failed; lazygit, which needs neither, runs
assert_exit 1 run_steps ""
assert_contains "$RUN_OUTPUT" "The homebrew step failed."
assert_contains "$RUN_OUTPUT" "runtimes: skipped, homebrew failed"
assert_contains "$RUN_OUTPUT" "skills: skipped, runtimes failed"
assert_contains "$RUN_OUTPUT" "Failed steps: homebrew runtimes skills
Fix the errors above, then re-run them with: bash $0 homebrew runtimes skills"
assert_eq "homebrew
lazygit" "$(cat "$SANDBOX/ran")" "steps run after homebrew failed"

# homebrew isn't part of the run: runtimes runs
rm -f "$SANDBOX/ran"
assert_exit 0 run_steps "" runtimes
assert_eq "runtimes" "$(cat "$SANDBOX/ran")" "steps run without homebrew in the run"

# A --status report runs whatever failed before it
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps --status homebrew runtimes
assert_eq "homebrew --status
runtimes --status" "$(cat "$SANDBOX/ran")" "reports run after homebrew's failed"

# Every step's STEP_NEEDS names steps setup.sh runs, read the way run_steps reads it
known=" $(sed -n '/^MACOS_STEPS=(/,/)/p; /^UBUNTU_STEPS=(/,/)/p' "$REPO_DIR/setup.sh" | tr -d '()' |
    sed 's/^[A-Z_]*=//' | tr '\n' ' ') "
checked=0
while IFS= read -r script; do
    for need in $(step_header_value "$script" STEP_NEEDS); do
        checked=$((checked + 1))
        case "$known" in
            *" $need "*) ;;
            *) fail "${script#"$REPO_DIR"/} needs $need, which isn't a setup.sh step" ;;
        esac
    done
done < <(find "$REPO_DIR" -name install.sh -not -path '*/.git/*' -not -path '*/node_modules/*')
[ "$checked" -gt 0 ] || fail "no step has a STEP_NEEDS line"
test_done
