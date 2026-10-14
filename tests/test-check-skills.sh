#!/bin/bash
set -euo pipefail

# scripts/check-skills.sh passes on the repo's skills, and fails, naming the problem, on one bad
# fixture per check. Runs against a copy of the skills and the READMEs they link to. It runs the
# check about 40 times, at about 2 s each, so under load it needs more than the default limit.
# timeout: 300

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
yq --version 2>/dev/null | grep -q mikefarah || skip "mikefarah's yq isn't installed"

copy="$SANDBOX/repo"
skills="$copy/ai_tools/skills"
fresh_copy() {
    rm -rf "$copy"
    mkdir -p "$copy/ai_tools" "$copy/scripts/lib"
    cp "$REPO_DIR/README.md" "$copy/"
    cp "$REPO_DIR/ai_tools/README.md" "$copy/ai_tools/"
    cp -R "$REPO_DIR/ai_tools/skills" "$copy/ai_tools/"
    cp "$REPO_DIR/scripts/check-skills.sh" "$copy/scripts/"
    cp "$REPO_DIR/scripts/lib/markdown.sh" "$copy/scripts/lib/"
}
# edit <file under ai_tools/skills> <sed expression>, portably
edit() {
    sed "$2" "$skills/$1" > "$SANDBOX/edited" && mv "$SANDBOX/edited" "$skills/$1"
}
# Check that the copy fails, with a message containing the given text
expect_failure() {
    assert_exit 1 "$BASH" "$copy/scripts/check-skills.sh"
    assert_contains "$RUN_OUTPUT" "$1"
}

fresh_copy
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"
assert_eq "" "$RUN_OUTPUT" "check-skills output on the repo's skills"

# disable-model-invocation counts only in the frontmatter, so a body line mentioning it is fine
fresh_copy
printf '\ndisable-model-invocation: true\n' >> "$skills/engineering/tdd/SKILL.md"
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"

# allow_implicit_invocation outside policy:, where Codex ignores it
fresh_copy
printf 'interface:\n  display_name: "Bro"\n  allow_implicit_invocation: false\n' \
    > "$skills/productivity/bro/agents/openai.yaml"
expect_failure "productivity/bro/agents/openai.yaml: allow_implicit_invocation"

# An empty description, and a missing one
fresh_copy
edit engineering/tdd/SKILL.md 's/^description:.*/description: ""/'
expect_failure "engineering/tdd/SKILL.md: no description"
fresh_copy
edit engineering/tdd/SKILL.md '/^description:/d'
expect_failure "engineering/tdd/SKILL.md: no description"

# A name with characters outside lowercase letters, digits, and hyphens
fresh_copy
mv "$skills/engineering/tdd" "$skills/engineering/tdd_x"
edit engineering/tdd_x/SKILL.md 's/^name: tdd$/name: tdd_x/'
edit engineering/README.md 's|(./tdd/SKILL.md)|(./tdd_x/SKILL.md)|'
expect_failure "engineering/tdd_x/SKILL.md: the name \"tdd_x\""

# A name longer than 64 characters
long="$(printf 'a%.0s' $(seq 65))"
fresh_copy
mv "$skills/engineering/tdd" "$skills/engineering/$long"
edit "engineering/$long/SKILL.md" "s/^name: tdd\$/name: $long/"
edit engineering/README.md "s|(./tdd/SKILL.md)|(./$long/SKILL.md)|"
expect_failure "engineering/$long/SKILL.md: the name \"$long\""

# Names with a leading, trailing, or doubled hyphen, one per skill in a single copy
fresh_copy
rename_skill() {
    mv -- "$skills/engineering/$1" "$skills/engineering/$2"
    edit "engineering/$2/SKILL.md" "s/^name: $1\$/name: $2/"
    edit engineering/README.md "s|(./$1/SKILL.md)|(./$2/SKILL.md)|"
}
rename_skill tdd -tdd
rename_skill research research-
rename_skill to-spec to--spec
expect_failure "engineering/-tdd/SKILL.md: the name \"-tdd\""
assert_contains "$RUN_OUTPUT" "engineering/research-/SKILL.md: the name \"research-\""
assert_contains "$RUN_OUTPUT" "engineering/to--spec/SKILL.md: the name \"to--spec\""

# A description over 1024 characters and short_descriptions outside 25-64, then each at its limit
repeat_a() {
    printf 'a%.0s' $(seq "$1")
}
fresh_copy
edit engineering/tdd/SKILL.md "s/^description:.*/description: $(repeat_a 1025)/"
edit engineering/tdd/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_a 24)\"/"
edit engineering/research/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_a 65)\"/"
expect_failure "engineering/tdd/SKILL.md: the description is 1025 characters, over 1024"
assert_contains "$RUN_OUTPUT" "engineering/tdd/agents/openai.yaml: interface.short_description is 24 characters, not 25-64"
assert_contains "$RUN_OUTPUT" "engineering/research/agents/openai.yaml: interface.short_description is 65 characters, not 25-64"
fresh_copy
edit engineering/tdd/SKILL.md "s/^description:.*/description: $(repeat_a 1024)/"
edit engineering/tdd/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_a 25)\"/"
edit engineering/research/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_a 64)\"/"
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"

# Lengths count characters, not bytes: each é is two bytes in UTF-8
repeat_e() {
    printf '\303\251%.0s' $(seq "$1")
}
fresh_copy
edit engineering/tdd/SKILL.md "s/^description:.*/description: $(repeat_e 1024)/"
edit engineering/tdd/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_e 64)\"/"
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"
fresh_copy
edit engineering/tdd/SKILL.md "s/^description:.*/description: $(repeat_e 1025)/"
edit engineering/tdd/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_e 65)\"/"
expect_failure "engineering/tdd/SKILL.md: the description is 1025 characters, over 1024"
assert_contains "$RUN_OUTPUT" "engineering/tdd/agents/openai.yaml: interface.short_description is 65 characters, not 25-64"

# A name that differs from the skill's directory
fresh_copy
edit engineering/tdd/SKILL.md 's/^name: tdd$/name: tdd-loop/'
expect_failure "engineering/tdd/SKILL.md: the name \"tdd-loop\" differs from the directory name \"tdd\""

# No agents/openai.yaml
fresh_copy
rm "$skills/engineering/tdd/agents/openai.yaml"
expect_failure "engineering/tdd: no agents/openai.yaml"

# Invocation that disagrees: SKILL.md turns off model invocation, but openai.yaml and the
# README's heading still have it on
fresh_copy
edit engineering/tdd/SKILL.md 's/^name: tdd$/name: tdd\
disable-model-invocation: true/'
expect_failure "engineering/tdd/agents/openai.yaml: SKILL.md has disable-model-invocation: true, but policy.allow_implicit_invocation isn't false"
assert_contains "$RUN_OUTPUT" "engineering/README.md: lists tdd under \"Model-invoked\", not \"User-invoked\""
# openai.yaml turns it off, but SKILL.md doesn't
fresh_copy
printf 'policy:\n  allow_implicit_invocation: false\n' >> "$skills/engineering/tdd/agents/openai.yaml"
expect_failure "engineering/tdd/agents/openai.yaml: allow_implicit_invocation is false, but SKILL.md has no disable-model-invocation: true"
# The README lists the skill under the other heading
fresh_copy
grep -v '(./tdd/SKILL.md)' "$skills/engineering/README.md" > "$SANDBOX/edited"
grep '(./tdd/SKILL.md)' "$skills/engineering/README.md" > "$SANDBOX/tdd-line"
awk -v line="$(cat "$SANDBOX/tdd-line")" '{ print } $0 == "## User-invoked" { print ""; print line }' \
    "$SANDBOX/edited" > "$skills/engineering/README.md"
expect_failure "engineering/README.md: lists tdd under \"User-invoked\", not \"Model-invoked\""

# A link from a skill to a file outside it that isn't another skill: another category's skill,
# and the category README. Both resolve in the repo, but not once installed.
fresh_copy
printf '\n[unslop](../../productivity/unslop/SKILL.md)\n' >> "$skills/engineering/tdd/SKILL.md"
expect_failure "engineering/tdd/SKILL.md: a link outside the skill to ../../productivity/unslop/SKILL.md"
fresh_copy
printf '\n[up](../README.md)\n' >> "$skills/engineering/tdd/SKILL.md"
expect_failure "engineering/tdd/SKILL.md: a link outside the skill to ../README.md"

# Broken links and anchors in the category and top-level READMEs
fresh_copy
printf '\n[gone](./gone.md)\n' >> "$skills/engineering/README.md"
expect_failure "engineering/README.md: broken link to ./gone.md"
fresh_copy
printf '\n[gone](../README.md#no-such-section)\n' >> "$skills/productivity/README.md"
expect_failure "productivity/README.md: broken anchor in ../README.md#no-such-section"
fresh_copy
printf '\n[gone](#no-such-section)\n' >> "$skills/README.md"
expect_failure "README.md: broken anchor in #no-such-section"
fresh_copy
edit README.md 's|(../README.md#skills)|(../README.md#no-skills)|'
expect_failure "README.md: broken anchor in ../README.md#no-skills"

# A frontmatter nothing closes, and one that isn't valid YAML, as an unquoted ": " makes it
fresh_copy
edit engineering/tdd/SKILL.md '2,/^---$/{/^---$/d;}'
expect_failure "engineering/tdd/SKILL.md: no frontmatter closed by ---"
fresh_copy
edit engineering/tdd/SKILL.md 's/^description:.*/description: TDD: builds features/'
expect_failure "engineering/tdd/SKILL.md: the frontmatter isn't a YAML mapping"
# A description written as a block scalar is fine
fresh_copy
edit engineering/tdd/SKILL.md 's/^description: \(.*\)/description: >-\
  \1/'
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"

# An agents/openai.yaml that isn't valid YAML
fresh_copy
printf 'interface:\n  display_name: "TDD\n' > "$skills/engineering/tdd/agents/openai.yaml"
expect_failure "engineering/tdd/agents/openai.yaml: isn't valid YAML"

# A skill the category README lists twice, once under each heading, and one it doesn't list
fresh_copy
awk -v line="$(grep '(./tdd/SKILL.md)' "$skills/engineering/README.md")" \
    '{ print } $0 == "## User-invoked" { print ""; print line }' \
    "$skills/engineering/README.md" > "$SANDBOX/edited"
mv "$SANDBOX/edited" "$skills/engineering/README.md"
expect_failure "engineering/README.md: lists tdd more than once, under: User-invoked, Model-invoked"
fresh_copy
grep -v '(./tdd/SKILL.md)' "$skills/engineering/README.md" > "$SANDBOX/edited"
mv "$SANDBOX/edited" "$skills/engineering/README.md"
expect_failure "engineering/README.md: doesn't list tdd, under \"Model-invoked\""

# A SKILL.md nested deeper than <category>/<skill>/ is reported, and the other skills are still
# checked
fresh_copy
mkdir -p "$skills/engineering/tdd/extra"
cp "$skills/engineering/tdd/SKILL.md" "$skills/engineering/tdd/extra/SKILL.md"
rm "$skills/productivity/bro/agents/openai.yaml"
expect_failure "engineering/tdd/extra/SKILL.md: isn't at <category>/<skill>/SKILL.md"
assert_contains "$RUN_OUTPUT" "productivity/bro: no agents/openai.yaml"

# The paths a skill names to its own and other skills' files, one of each kind. Ones that exist
# pass: backquoted paths to another category's skill, a relative path from SKILL.md and from
# references/, a code fence's words, and ${CLAUDE_SKILL_DIR} paths to this skill and another.
# Placeholders, shell variables, and globs aren't files to check. Then each kind fails, naming
# the file and the path, when its target doesn't exist.
why="$skills/productivity/why"
interrogate="$skills/engineering/interrogate"
fresh_copy
printf '\nRead `../unslop/SKILL.md` and `ai_tools/skills/productivity/unslop/SKILL.md`.\n' >> "$skills/engineering/tdd/SKILL.md"
echo 'Read `references/epistemics.md` first.' >> "$why/SKILL.md"
echo 'See `sources/slack.md`.' >> "$why/references/source-playbook.md"
printf '%s\n' '```sh' 'bash scripts/run-reviewer.sh "$out" scripts/<name>.sh "$dir/scripts/x.sh" scripts/*.sh' '```' \
    'Run `${CLAUDE_SKILL_DIR}/scripts/run-reviewer.sh`, or ${CLAUDE_SKILL_DIR}/../why/references/rubric.md.' \
    'Or `${CLAUDE_SKILL_DIR}/scripts/<script>.sh` or ${CLAUDE_SKILL_DIR}/scripts/$name.' >> "$interrogate/SKILL.md"
sed 's|why/references/rubric.md|why/references/epistemics.md|' "$interrogate/SKILL.md" > "$SANDBOX/edited" &&
    mv "$SANDBOX/edited" "$interrogate/SKILL.md"
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"
assert_eq "" "$RUN_OUTPUT" "check-skills output on paths that exist"
fresh_copy
printf '\nRead `../unslop/gone.md`, `../README.md`, and `ai_tools/skills/x/SKILL.md`.\n' >> "$skills/engineering/tdd/SKILL.md"
echo 'Read `references/missing.md` first.' >> "$why/SKILL.md"
echo 'See `sources/gone.md`.' >> "$why/references/source-playbook.md"
printf '%s\n' '```sh' 'bash scripts/missing.sh "$out"' '```' \
    'Run `${CLAUDE_SKILL_DIR}/scripts/gone.sh`, or ${CLAUDE_SKILL_DIR}/../why/references/nope.md.' >> "$interrogate/SKILL.md"
expect_failure "engineering/tdd/SKILL.md: a path to another skill's file, ../unslop/gone.md, that doesn't exist"
assert_contains "$RUN_OUTPUT" "engineering/tdd/SKILL.md: a path to another skill's file, ../README.md, that doesn't exist"
assert_contains "$RUN_OUTPUT" "engineering/tdd/SKILL.md: a path to another skill's file, ai_tools/skills/x/SKILL.md, that doesn't exist"
assert_contains "$RUN_OUTPUT" "productivity/why/SKILL.md: names references/missing.md, which doesn't exist"
assert_contains "$RUN_OUTPUT" "productivity/why/references/source-playbook.md: names sources/gone.md, which doesn't exist"
assert_contains "$RUN_OUTPUT" "engineering/interrogate/SKILL.md: names scripts/missing.sh, which doesn't exist"
assert_contains "$RUN_OUTPUT" "engineering/interrogate/SKILL.md: names \${CLAUDE_SKILL_DIR}/scripts/gone.sh, which doesn't exist"
assert_contains "$RUN_OUTPUT" "engineering/interrogate/SKILL.md: names \${CLAUDE_SKILL_DIR}/../why/references/nope.md, which doesn't exist"
assert_eq 8 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c .)" "the number of broken paths reported"

# A skill script that isn't executable, on disk outside git, and in git's index
fresh_copy
chmod -x "$skills/engineering/interrogate/scripts/run-reviewer.sh"
expect_failure "engineering/interrogate/scripts/run-reviewer.sh: isn't executable"
fresh_copy
git -C "$copy" init -q
git -C "$copy" add -A
git -C "$copy" update-index --chmod=-x ai_tools/skills/engineering/interrogate/scripts/run-reviewer.sh
expect_failure "engineering/interrogate/scripts/run-reviewer.sh: isn't executable in git"

# A symlink in a skill: the skills CLI copies its target as a file, so the installed copy would
# never match
fresh_copy
ln -s SKILL.md "$skills/engineering/tdd/link.md"
expect_failure "engineering/tdd/link.md: a symlink"

# Upstream notices: each skill the README's Acknowledgements credits carries its source's notice
# from THIRD_PARTY_LICENSES in a LICENSE file, and no other skill has one
fresh_copy
rm "$skills/engineering/tdd/LICENSE"
expect_failure "engineering/tdd: no LICENSE"
fresh_copy
edit engineering/tdd/LICENSE 's/Matt Pocock/Someone Else/'
expect_failure "engineering/tdd/LICENSE: doesn't match"
fresh_copy
cp "$skills/productivity/unslop/LICENSE" "$skills/engineering/tdd/LICENSE"
expect_failure "engineering/tdd/LICENSE: names https://github.com/cursor/plugins/tree/main/pstack"
fresh_copy
cp "$skills/engineering/tdd/LICENSE" "$skills/engineering/code-review/LICENSE"
expect_failure "engineering/code-review/LICENSE: the README's Acknowledgements don't credit code-review"
fresh_copy
edit README.md 's/research, tdd,/research, tdd, tdd-two,/'
expect_failure "README.md: the Acknowledgements credit tdd-two, which isn't a skill here"

# One copy holds a problem per skill, since each check runs on every skill:
# - a frontmatter key Claude Code doesn't support, such as a typo of argument-hint
# - openai.yaml with no display_name, an empty short_description, and a key Codex doesn't read
# - a skill directory with no SKILL.md, which the installer would skip
# - user-invocable that isn't true or false
# - user-invocable: false with disable-model-invocation: true, so nothing can invoke the skill
fresh_copy
edit engineering/tdd/SKILL.md 's/^name: tdd$/name: tdd\
argument-hnt: "[x]"/'
printf 'interface:\n  short_description: ""\n  colour: red\n' > "$skills/engineering/code-review/agents/openai.yaml"
mkdir -p "$skills/engineering/orphan/references"
echo 'Notes' > "$skills/engineering/orphan/references/notes.md"
edit engineering/research/SKILL.md 's/^name: research$/name: research\
user-invocable: maybe/'
edit engineering/to-spec/SKILL.md 's/^name: to-spec$/name: to-spec\
user-invocable: false/'
expect_failure "engineering/tdd/SKILL.md: the frontmatter has argument-hnt, which isn't a SKILL.md field"
assert_contains "$RUN_OUTPUT" "engineering/code-review/agents/openai.yaml: no interface.display_name"
assert_contains "$RUN_OUTPUT" "engineering/code-review/agents/openai.yaml: no interface.short_description"
assert_contains "$RUN_OUTPUT" "engineering/code-review/agents/openai.yaml: interface.colour isn't an openai.yaml field"
assert_contains "$RUN_OUTPUT" "engineering/orphan: no SKILL.md"
assert_contains "$RUN_OUTPUT" "engineering/research/SKILL.md: user-invocable is maybe, not true or false"
assert_contains "$RUN_OUTPUT" "engineering/to-spec/SKILL.md: user-invocable: false and disable-model-invocation: true, so nothing can invoke it"
# user-invocable: false on a model-invoked skill is fine, and changes nothing for Codex
fresh_copy
edit engineering/tdd/SKILL.md 's/^name: tdd$/name: tdd\
user-invocable: false/'
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"

# Without mikefarah's yq it says how to install it
fresh_copy
hide yq
assert_exit 1 "$BASH" "$copy/scripts/check-skills.sh"
assert_contains "$RUN_OUTPUT" "brew install yq"
test_done
