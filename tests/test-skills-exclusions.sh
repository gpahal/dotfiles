#!/bin/bash
set -euo pipefail

# The skills step's checks leave out what the skills CLI doesn't copy (metadata.json, .git,
# __pycache__, __pypackages__), and still see a real content change. test-skills.sh covers a mode
# change. tests/skills-cli-stub.sh stands in for the skills CLI.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox

# shellcheck source=skills-cli-stub.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills-cli-stub.sh"

# The CLI leaves metadata.json, .git, __pycache__, and __pypackages__ out of its copies, so the
# step leaves them out of its checks too. A fixture copy of the repo, with only the interrogate
# skill, gets them.
skills_fixture engineering/interrogate
SRC="$FIXTURE/ai_tools/skills/engineering/interrogate"
step
assert_eq 0 "$RUN_STATUS" "the fixture's first run"
# Each left-out entry in the source, at the top and at depth, with an executable file inside
entries="metadata.json scripts/metadata.json .git scripts/__pycache__ __pycache__ __pypackages__"
for entry in $entries; do
    case "$entry" in
        *metadata.json) echo '{}' > "$SRC/$entry"; chmod +x "$SRC/$entry" ;;
        *) mkdir -p "$SRC/$entry" && echo x > "$SRC/$entry/run.sh" && chmod +x "$SRC/$entry/run.sh" ;;
    esac
done
assert_exit 0 "$BASH" "$STEP" --status
assert_not_contains "$RUN_OUTPUT" "interrogate skill" "status with left-out entries in the source"
for entry in $entries; do
    rm -rf "${SRC:?}/$entry"
done
# A cache a skill's script wrote into the installed copy isn't an edit
mkdir -p "$AGENTS_DIR/interrogate/scripts/__pycache__"
echo x > "$AGENTS_DIR/interrogate/scripts/__pycache__/run.pyc"
assert_exit 0 "$BASH" "$STEP" --status
# A real difference still counts, and the add's check passes with left-out entries in the source
mkdir -p "$SRC/__pycache__"
echo x > "$SRC/__pycache__/run.pyc"
echo '{}' > "$SRC/metadata.json"
echo "drift" >> "$SRC/SKILL.md"
assert_exit 3 "$BASH" "$STEP" --status
assert_contains "$RUN_OUTPUT" "interrogate skill"
rm -rf "$BACKUPS"
step
assert_eq 0 "$RUN_STATUS" "status after adding a skill whose source has left-out entries"
assert_not_contains "$RUN_OUTPUT" "wasn't installed correctly"
assert_eq "" "$(backups interrogate)" "backups of a copy whose only extra is a cache"
assert_file_contains "$AGENTS_DIR/interrogate/SKILL.md" "drift"
[ ! -e "$AGENTS_DIR/interrogate/metadata.json" ] || fail "the stub copied metadata.json"
assert_exit 0 "$BASH" "$STEP" --status
# Any other untracked file is part of the skill, and gets installed
echo "notes" > "$SRC/notes.md"
assert_exit 3 "$BASH" "$STEP" --status
step
assert_file_contains "$AGENTS_DIR/interrogate/notes.md" "notes"
assert_exit 0 "$BASH" "$STEP" --status
test_done
