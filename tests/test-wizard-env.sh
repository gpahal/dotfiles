#!/bin/bash
set -euo pipefail

# The wizard template's _existing and write_env read and replace whole .env assignments, including
# quoted values that span several lines. write_env writes through a symlinked .env.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox

# The library is everything above the STAGES marker; below it is the example wizard.
sed '/^# STAGES:/,$d' "$REPO_DIR/ai_tools/skills/engineering/wizard/template.sh" > "$SANDBOX/wizard-lib.sh"
# shellcheck source=/dev/null
source "$SANDBOX/wizard-lib.sh"

ENV_FILE="$SANDBOX/.env"
nl=$'\n'

# Each fixture assignment, in file order. MULTI_DQ holds a line that looks like an assignment.
before='BEFORE=keep'
multi_dq="MULTI_DQ=\"first${nl}AFTER=inside${nl}third\""
multi_sq="MULTI_SQ='one${nl}two'"
escaped='ESCAPED="say \"hi\" there"'
plain='PLAIN=value'
after="AFTER='x'"

fixture() {
    printf '%s\n' "$before" "$multi_dq" "$multi_sq" "$escaped" "$plain" "$after" > "$ENV_FILE"
}

# The fixture's contents with one assignment left out, then KEY=new appended
expected_after_replace() {
    local skip="$1" key="$2" part
    for part in "$before" "$multi_dq" "$multi_sq" "$escaped" "$plain" "$after"; do
        [ "$part" == "$skip" ] || printf '%s\n' "$part"
    done
    printf '%s=new\n' "$key"
}

check_key() {
    local key="$1" value="$2" assignment="$3"
    fixture
    assert_eq "$value" "$(_existing "$key")" "_existing $key"
    write_env "$key" new > /dev/null
    assert_eq "$(expected_after_replace "$assignment" "$key")" "$(cat "$ENV_FILE")" "file after replacing $key"
    assert_eq new "$(_existing "$key")" "_existing $key after replacing it"
}

check_key MULTI_DQ "first${nl}AFTER=inside${nl}third" "$multi_dq"
check_key MULTI_SQ "one${nl}two" "$multi_sq"
check_key ESCAPED 'say \"hi\" there' "$escaped"
check_key PLAIN value "$plain"
check_key AFTER x "$after"

# A missing key
fixture
_existing MISSING > /dev/null && fail "_existing found a key the file lacks"

# A quote that never closes is a one-line value, so the lines after it stay
printf '%s\n' 'OPEN="abc' 'NEXT=1' > "$ENV_FILE"
assert_eq '"abc' "$(_existing OPEN)" "_existing of an unclosed quote"
write_env OPEN new > /dev/null
assert_eq "NEXT=1${nl}OPEN=new" "$(cat "$ENV_FILE")" "file after replacing an unclosed quote"

# The writer's own multiline format reads back unchanged and is replaced whole
fixture
write_env PEM "-----BEGIN-----${nl}body${nl}-----END-----" > /dev/null
assert_file_contains "$ENV_FILE" 'PEM="-----BEGIN-----\nbody\n-----END-----"'
assert_eq "-----BEGIN-----${nl}body${nl}-----END-----" "$(_existing PEM)" "_existing of a written multiline value"
write_env PEM short > /dev/null
assert_eq 1 "$(grep -c '^PEM=' "$ENV_FILE")" "PEM assignments"
assert_eq "$(expected_after_replace '' PEM | sed 's/^PEM=new$/PEM=short/')" "$(cat "$ENV_FILE")" "file after replacing PEM"

# Keeping a hand-edited value doesn't turn its inline comment into part of the secret.
for assignment in 'TOKEN=old # note' 'TOKEN=old#note' '  export TOKEN = old  # note'; do
    printf '%s\n' "$assignment" > "$ENV_FILE"
    value="$(_existing TOKEN || true)"
    assert_eq old "$value" "unquoted dotenv value"
    write_env TOKEN "$value" > /dev/null
    assert_eq 'TOKEN=old' "$(cat "$ENV_FILE")" "dotenv value kept on rewrite"
done
printf '%s\n' 'TOKEN="old # literal" # note' > "$ENV_FILE"
assert_eq 'old # literal' "$(_existing TOKEN)" "quoted hash preserved"

# A symlinked .env is written through, so the link and its target's mode stay
printf 'KEEP=1\n' > "$SANDBOX/real.env"
chmod 600 "$SANDBOX/real.env"
ln -s real.env "$ENV_FILE.link"
ENV_FILE="$ENV_FILE.link" write_env ADDED 2 > /dev/null
[ -L "$ENV_FILE.link" ] || fail "write_env replaced the symlinked .env with a file"
assert_eq "KEEP=1${nl}ADDED=2" "$(cat "$SANDBOX/real.env")" "the symlink's target after write_env"
assert_eq "$SANDBOX/real.env" "$(find "$SANDBOX/real.env" -perm 600)" "the target's mode after write_env"

# A new .env is readable only by you; an existing one keeps its mode
rm -f "$ENV_FILE"
(umask 022; write_env NEW 1 > /dev/null)
assert_eq "$ENV_FILE" "$(find "$ENV_FILE" -perm 600)" "a new .env's mode"
chmod 644 "$ENV_FILE"
(umask 077; write_env NEW 2 > /dev/null)
assert_eq "$ENV_FILE" "$(find "$ENV_FILE" -perm 644)" "an existing .env's mode after write_env"

# Without a terminal, the wizard stops before asking anything, so it writes no empty values. perl
# starts it in a new session, which has no controlling terminal even when the tests run in one.
no_tty() {
    perl -MPOSIX -e 'if (my $pid = fork) { waitpid($pid, 0); exit($? >> 8) } POSIX::setsid(); exec @ARGV or exit 127' "$@"
}
rm -f "$ENV_FILE"
cd "$SANDBOX"
ENV_FILE="$ENV_FILE" assert_exit 1 no_tty bash "$REPO_DIR/ai_tools/skills/engineering/wizard/template.sh"
assert_contains "$RUN_OUTPUT" "no terminal"
[ ! -e "$ENV_FILE" ] || fail "the wizard wrote $ENV_FILE without a terminal"
test_done
