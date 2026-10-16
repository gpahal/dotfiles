#!/bin/bash
set -euo pipefail

# scripts/check-skills.sh passes on the repo's skills and on edge cases that are fine, and fails,
# naming each problem, on a copy with one problem per skill. Each run checks every skill and takes
# seconds, so one copy holds every edge case and one every problem. Runs against a copy of the
# skills and the READMEs they link to.

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

repeat_a() {
    printf 'a%.0s' $(seq "$1")
}
# Lengths count characters, not bytes: each é is two bytes in UTF-8
repeat_e() {
    printf '\303\251%.0s' $(seq "$1")
}

# Edge cases that pass:
# - disable-model-invocation counts only in the frontmatter, so a body line mentioning it is fine
# - a description and short_descriptions at their limits, in ASCII and in two-byte characters
# - a description written as a block scalar
# - user-invocable: false on a model-invoked skill, which changes nothing for Codex
# - the paths a skill names to its own and other skills' files, when they exist: backquoted paths
#   to another category's skill, a relative path from SKILL.md and from references/, a code
#   fence's words, and ${CLAUDE_SKILL_DIR} paths to this skill and another. Placeholders, shell
#   variables, and globs aren't files to check.
why="$skills/productivity/why"
interrogate="$skills/engineering/interrogate"
fresh_copy
printf '\ndisable-model-invocation: true\n' >> "$skills/engineering/tdd/SKILL.md"
edit engineering/tdd/SKILL.md "s/^description:.*/description: $(repeat_e 1024)/"
edit engineering/tdd/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_e 64)\"/"
edit engineering/research/SKILL.md "s/^description:.*/description: $(repeat_a 1024)/"
edit engineering/research/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_a 25)\"/"
edit engineering/diagnosing-bugs/SKILL.md 's/^description: \(.*\)/description: >-\
  \1/'
edit engineering/wizard/SKILL.md 's/^name: wizard$/name: wizard\
user-invocable: false/'
printf '\nRead `../unslop/SKILL.md` and `ai_tools/skills/productivity/unslop/SKILL.md`.\n' >> "$skills/engineering/tdd/SKILL.md"
echo 'Read `references/epistemics.md` first.' >> "$why/SKILL.md"
echo 'See `sources/slack.md`.' >> "$why/references/source-playbook.md"
printf '%s\n' '```sh' 'bash scripts/run-reviewer.sh "$out" scripts/<name>.sh "$dir/scripts/x.sh" scripts/*.sh' '```' \
    'Run `${CLAUDE_SKILL_DIR}/scripts/run-reviewer.sh`, or ${CLAUDE_SKILL_DIR}/../why/references/epistemics.md.' \
    'Or `${CLAUDE_SKILL_DIR}/scripts/<script>.sh` or ${CLAUDE_SKILL_DIR}/scripts/$name.' >> "$interrogate/SKILL.md"
assert_exit 0 "$BASH" "$copy/scripts/check-skills.sh"
assert_eq "" "$RUN_OUTPUT" "check-skills output on the edge cases that pass"

# One copy with a problem per skill, or per README, each of which the check reports
fresh_copy
# A name that differs from the skill's directory
edit engineering/tdd/SKILL.md 's/^name: tdd$/name: tdd-loop/'
# A description over 1024 characters, counted in characters, and short_descriptions outside 25-64
edit engineering/research/SKILL.md "s/^description:.*/description: $(repeat_e 1025)/"
edit engineering/research/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_a 24)\"/"
edit engineering/code-review-stds-and-spec/agents/openai.yaml "s/short_description:.*/short_description: \"$(repeat_e 65)\"/"
# No description
edit engineering/to-spec/SKILL.md '/^description:/d'
# No agents/openai.yaml
rm "$skills/engineering/code-review/agents/openai.yaml"
# Invocation that disagrees: SKILL.md turns off model invocation, but openai.yaml and the README's
# heading still have it on; and openai.yaml turns it off, but SKILL.md doesn't
edit engineering/diagnosing-bugs/SKILL.md 's/^name: diagnosing-bugs$/name: diagnosing-bugs\
disable-model-invocation: true/'
printf 'policy:\n  allow_implicit_invocation: false\n' >> "$skills/engineering/wizard/agents/openai.yaml"
# allow_implicit_invocation outside policy:, where Codex ignores it
printf 'interface:\n  display_name: "Grill"\n  allow_implicit_invocation: false\n' \
    > "$skills/productivity/grill/agents/openai.yaml"
# A link from a skill to a file outside it that isn't another skill. It resolves in the repo, but
# not once installed.
printf '\n[up](../README.md)\n' >> "$skills/engineering/implement/SKILL.md"
# Broken links and anchors in the category READMEs
printf '\n[gone](./gone.md)\n' >> "$skills/engineering/README.md"
printf '\n[gone](../README.md#no-such-section)\n' >> "$skills/productivity/README.md"
# A frontmatter nothing closes, and one that isn't valid YAML, as an unquoted ": " makes it
edit engineering/architect/SKILL.md '2,/^---$/{/^---$/d;}'
edit engineering/to-tickets/SKILL.md 's/^description:.*/description: Tickets: break a plan up/'
# An agents/openai.yaml that isn't valid YAML
printf 'interface:\n  display_name: "Bro\n' > "$skills/productivity/bro/agents/openai.yaml"
# A skill the category README doesn't list
grep -v '(./unslop/SKILL.md)' "$skills/productivity/README.md" > "$SANDBOX/edited"
mv "$SANDBOX/edited" "$skills/productivity/README.md"
# A SKILL.md nested deeper than <category>/<skill>/
mkdir -p "$skills/engineering/code-review-stds-and-spec/extra"
cp "$skills/engineering/tdd/SKILL.md" "$skills/engineering/code-review-stds-and-spec/extra/SKILL.md"
# A skill directory with no SKILL.md, which the installer would skip
mkdir -p "$skills/engineering/orphan/references"
echo 'Notes' > "$skills/engineering/orphan/references/notes.md"
# Paths to a skill's own and another skill's files that don't exist
echo 'Read `references/missing.md` first.' >> "$why/SKILL.md"
printf '\nRead `../unslop/gone.md`.\n' >> "$skills/productivity/writing-for-agents/SKILL.md"
printf '%s\n' 'Run `${CLAUDE_SKILL_DIR}/scripts/gone.sh`.' >> "$skills/productivity/show-me-your-work/SKILL.md"
# A skill script that isn't executable
chmod -x "$skills/engineering/interrogate/scripts/run-reviewer.sh"
# A symlink in a skill: the skills CLI copies its target as a file, so the installed copy would
# never match
ln -s SKILL.md "$skills/engineering/rewrite-docs/link.md"
# Upstream notices: a credited skill with no LICENSE, one whose LICENSE doesn't match
# THIRD_PARTY_LICENSES, and a credit for a skill that isn't here
rm "$skills/productivity/handoff/LICENSE"
edit engineering/to-spec/LICENSE 's/Matt Pocock/Someone Else/'
edit README.md 's/research, tdd,/research, tdd, tdd-two,/'
# A frontmatter key Claude Code doesn't support, user-invocable that isn't true or false, and
# user-invocable: false with disable-model-invocation: true, so nothing can invoke the skill
edit productivity/technical-writing/SKILL.md 's/^name: technical-writing$/name: technical-writing\
argument-hnt: "[x]"/'
edit productivity/why/SKILL.md 's/^name: why$/name: why\
user-invocable: maybe/'
edit productivity/wait-what/SKILL.md 's/^name: wait-what$/name: wait-what\
user-invocable: false/'
expect_failure "engineering/tdd/SKILL.md: the name \"tdd-loop\" differs from the directory name \"tdd\""
for message in \
    "engineering/research/SKILL.md: the description is 1025 characters, over 1024" \
    "engineering/research/agents/openai.yaml: interface.short_description is 24 characters, not 25-64" \
    "engineering/code-review-stds-and-spec/agents/openai.yaml: interface.short_description is 65 characters, not 25-64" \
    "engineering/to-spec/SKILL.md: no description" \
    "engineering/code-review: no agents/openai.yaml" \
    "engineering/diagnosing-bugs/agents/openai.yaml: SKILL.md has disable-model-invocation: true, but policy.allow_implicit_invocation isn't false" \
    "engineering/README.md: lists diagnosing-bugs under \"Model-invoked\", not \"User-invoked\"" \
    "engineering/wizard/agents/openai.yaml: allow_implicit_invocation is false, but SKILL.md has no disable-model-invocation: true" \
    "productivity/grill/agents/openai.yaml: allow_implicit_invocation" \
    "engineering/implement/SKILL.md: a link outside the skill to ../README.md" \
    "engineering/README.md: broken link to ./gone.md" \
    "productivity/README.md: broken anchor in ../README.md#no-such-section" \
    "engineering/architect/SKILL.md: no frontmatter closed by ---" \
    "engineering/to-tickets/SKILL.md: the frontmatter isn't a YAML mapping" \
    "productivity/bro/agents/openai.yaml: isn't valid YAML" \
    "productivity/README.md: doesn't list unslop, under \"Model-invoked\"" \
    "engineering/code-review-stds-and-spec/extra/SKILL.md: isn't at <category>/<skill>/SKILL.md" \
    "engineering/orphan: no SKILL.md" \
    "productivity/why/SKILL.md: names references/missing.md, which doesn't exist" \
    "productivity/writing-for-agents/SKILL.md: a path to another skill's file, ../unslop/gone.md, that doesn't exist" \
    "productivity/show-me-your-work/SKILL.md: names \${CLAUDE_SKILL_DIR}/scripts/gone.sh, which doesn't exist" \
    "engineering/interrogate/scripts/run-reviewer.sh: isn't executable" \
    "engineering/rewrite-docs/link.md: a symlink" \
    "productivity/handoff: no LICENSE" \
    "engineering/to-spec/LICENSE: doesn't match" \
    "README.md: the Acknowledgements credit tdd-two, which isn't a skill here" \
    "productivity/technical-writing/SKILL.md: the frontmatter has argument-hnt, which isn't a SKILL.md field" \
    "productivity/why/SKILL.md: user-invocable is maybe, not true or false" \
    "productivity/wait-what/SKILL.md: user-invocable: false and disable-model-invocation: true, so nothing can invoke it"; do
    assert_contains "$RUN_OUTPUT" "$message"
done

# Without mikefarah's yq it says how to install it
fresh_copy
hide yq
assert_exit 1 "$BASH" "$copy/scripts/check-skills.sh"
assert_contains "$RUN_OUTPUT" "brew install yq"
test_done
