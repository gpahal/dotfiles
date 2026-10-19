#!/bin/bash
set -euo pipefail

# ssh/add-host.sh adds a Host block for an alias, once. It rejects an alias or hostname ssh would
# read as several patterns or a comment, and puts the block above a Host * block, so the
# catch-all's settings don't win over it. It finds a block however ssh would read its Host line,
# and fails without saying it added one when it can't write the config.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v ssh &>/dev/null || skip "ssh isn't installed"
add_host() {
    bash "$REPO_DIR/ssh/add-host.sh" "$@"
}
config="$HOME/.ssh/config"

# A new config gets the block, and a second run leaves it alone
assert_exit 0 add_host box box.example.ts.net
assert_contains "$RUN_OUTPUT" "ssh -O exit box closes it"
assert_file_contains "$config" "Host box"
assert_file_contains "$config" "  HostName box.example.ts.net"
cp "$config" "$SANDBOX/config-before"
assert_exit 0 add_host box box.example.ts.net
assert_contains "$RUN_OUTPUT" "already has a block for box"
cmp -s "$SANDBOX/config-before" "$config" || fail "a second run changed the config"

# An alias or hostname with a space, a wildcard, a comment, or a newline is rejected, and the
# config is left alone
for bad in "my box" "*" "box#1" "$(printf 'a\nb')"; do
    assert_exit 2 add_host "$bad"
    assert_contains "$RUN_OUTPUT" "can't contain"
    assert_exit 2 add_host ok "$bad"
done
cmp -s "$SANDBOX/config-before" "$config" || fail "a rejected alias changed the config"

# ssh matches Host patterns case-sensitively, so a block for box doesn't cover Box: Box gets its
# own block
assert_exit 0 add_host Box
assert_file_contains "$config" "Host Box"
assert_file_contains "$config" "Host box"

# A Host * block, with its comment, stays below the new block
cat > "$config" << 'EOF'
Host github.com
  HostName github.com

# Every host
Host *
  ServerAliveInterval 60
EOF
assert_exit 0 add_host box2
assert_eq "github.com box2 *" "$(awk '$1 == "Host" { printf "%s%s", sep, $2; sep = " " }' "$config")" \
    "the Host lines' order"
expected="Host github.com
  HostName github.com

Host box2
  HostName box2
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 1m

# Every host
Host *
  ServerAliveInterval 60"
assert_eq "$expected" "$(cat "$config")" "the config with a Host * block"
assert_exit 0 ssh -G -F "$config" box2
assert_contains "$RUN_OUTPUT" "serveraliveinterval 30"

# Any Host line listing the pattern *, however it's written, counts as the catch-all: the block goes
# above the first one
for star in 'Host * !bastion' 'Host foo *' 'Host "*"' "$(printf 'Host *\r')" 'host=*'; do
    printf 'Host github.com\n  HostName github.com\n\n%s\n  ServerAliveInterval 60\n' "$star" > "$config"
    assert_exit 0 add_host box3
    assert_eq "github.com box3" "$(awk '$1 == "Host" && NR < 9 { printf "%s%s", sep, $2; sep = " " }' "$config")" \
        "the Host lines above $star"
    assert_eq "$star" "$(sed -n 11p "$config")" "the catch-all after the block"
done

# A Match all is a catch-all too, as is a Host * whose defaults come from an included file. ssh -G
# shows the block's values, other hosts resolve as before, and a second run changes nothing.
printf 'Host *\n  ServerAliveInterval 6\n' > "$SANDBOX/star.conf"
# ssh refuses an included file others can write, which a umask of 0 would make
chmod 644 "$SANDBOX/star.conf"
for fixture in "Host other\n  User other\n\nHost *\n  Include $SANDBOX/star.conf" \
    "Host other\n  User other\n\nMatch all\n  ServerAliveInterval 5"; do
    # shellcheck disable=SC2059 # the fixtures hold \n
    printf "$fixture\n" > "$config"
    other_before="$(ssh -G -F "$config" other 2>&1)"
    assert_exit 0 add_host box5 box5.example.ts.net
    assert_exit 0 ssh -G -F "$config" box5
    assert_contains "$RUN_OUTPUT" "serveraliveinterval 30"
    assert_contains "$RUN_OUTPUT" "hostname box5.example.ts.net"
    assert_eq "$other_before" "$(ssh -G -F "$config" other 2>&1)" "another host with: $fixture"
    cp "$config" "$SANDBOX/config-before"
    assert_exit 0 add_host box5 box5.example.ts.net
    cmp -s "$SANDBOX/config-before" "$config" || fail "a second run changed the config with: $fixture"
done

# A block for the alias counts however its Host line is written, with = or quotes, or in
# lowercase, as ssh reads it: no second block goes above Host *
for existing in 'Host=box7' 'Host = box7' 'Host "box7"' 'host box7'; do
    printf '%s\n  User me\n\nHost *\n  ServerAliveInterval 60\n' "$existing" > "$config"
    cp "$config" "$SANDBOX/config-before"
    assert_exit 0 add_host box7
    assert_contains "$RUN_OUTPUT" "already has a block for box7"
    cmp -s "$SANDBOX/config-before" "$config" || fail "add-host added a block next to: $existing"
    assert_exit 0 ssh -G -F "$config" box7
    assert_contains "$RUN_OUTPUT" "user me"
done

# A config it can't write fails, without saying it added the block
if [ "$(id -u)" -ne 0 ]; then
    : > "$config"
    chmod 444 "$config"
    assert_exit 1 add_host box8
    assert_not_contains "$RUN_OUTPUT" "Added"
    chmod 600 "$config"
fi

# A symlinked config stays a symlink, with the block written to the file it points to
printf 'Host *\n  ServerAliveInterval 60\n' > "$SANDBOX/real-config"
rm "$config"
ln -s "$SANDBOX/real-config" "$config"
assert_exit 0 add_host box4
[ -L "$config" ] || fail "add-host replaced the symlinked config"
assert_eq "Host box4" "$(head -n 1 "$SANDBOX/real-config")" "the first line of the linked config"
assert_file_contains "$SANDBOX/real-config" "Host *"
test_done
