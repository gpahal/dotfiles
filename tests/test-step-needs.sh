#!/bin/bash
set -euo pipefail

# STEP_NEEDS gating in run_steps, and every STEP_NEEDS line naming a real step.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

steps="$SANDBOX/steps"
mkdir -p "$steps"
# fake_step <name> <needs> <body>
fake_step() {
    printf '%s\n' '#!/bin/bash' "STEP_NEEDS=\"$2\"" "echo \"$1\${*:+ \$*}\" >> \"$SANDBOX/ran\"" "$3" \
        > "$steps/$1.sh"
}
fake_step homebrew "" 'echo "Couldn'"'"'t download Homebrew'"'"'s installer." >&2; exit 1'
fake_step runtimes homebrew ''
fake_step lazygit "" ''
fake_step skills "runtimes" ''
# shellcheck disable=SC2034 # run_steps reads it
STEPS=(homebrew runtimes lazygit skills)
replace_fn step_script '[ -f "$steps/$1.sh" ] && echo "$steps/$1.sh"'

assert_exit 1 run_steps ""
assert_contains "$RUN_OUTPUT" "The homebrew step failed."
assert_contains "$RUN_OUTPUT" "runtimes: skipped, homebrew failed"
assert_contains "$RUN_OUTPUT" "skills: skipped, runtimes failed"
assert_contains "$RUN_OUTPUT" "Failed steps: homebrew runtimes skills
Fix the errors above, then re-run them with: bash $0 homebrew runtimes skills"
assert_eq "homebrew
lazygit" "$(cat "$SANDBOX/ran")" "steps run after homebrew failed"

rm -f "$SANDBOX/ran"
assert_exit 0 run_steps "" runtimes
assert_eq "runtimes" "$(cat "$SANDBOX/ran")" "steps run without homebrew in the run"

rm -f "$SANDBOX/ran"
assert_exit 1 run_steps --status homebrew runtimes
assert_eq "homebrew --status
runtimes --status" "$(cat "$SANDBOX/ran")" "reports run after homebrew's failed"

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
