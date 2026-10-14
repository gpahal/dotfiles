#!/bin/bash
set -euo pipefail

# ssh/add-host.sh adds a Host block for an alias, once. It rejects an alias or hostname ssh would
# read as several patterns or a comment, and puts the block above a Host * block, so the
# catch-all's settings don't win over it.

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

# An alias or hostname with a space, a wildcard, a negation, a list, a comment, a quote, or a
# newline is rejected, and the config is left alone
for bad in "my box" "*" "box?" "!box" "a,b" "box#1" 'box"' "box'" "$(printf 'a\nb')"; do
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

# just ssh-host passes each argument whole, so a space or a ; reaches the script as typed, not split
# or run
just="$(command -v just || true)"
if [ -n "$just" ]; then
    mkdir -p "$SANDBOX/repo/ssh"
    cp "$REPO_DIR/justfile" "$SANDBOX/repo/"
    printf '%s\n' 'printf "%s|" "$@" > "$ARGS"' > "$SANDBOX/repo/ssh/add-host.sh"
    export ARGS="$SANDBOX/args"
    assert_exit 0 "$just" --justfile "$SANDBOX/repo/justfile" ssh-host "my box" 'h;touch pwned'
    assert_eq "my box|h;touch pwned|" "$(cat "$ARGS")" "the arguments just ssh-host passes"
fi

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
  ControlPersist 10m

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

# A config that includes itself, which ssh rejects, still gets the block above its Host *, once
printf 'Include %s\nHost *\n  ServerAliveInterval 60\n' "$config" > "$config"
assert_exit 0 add_host box6
assert_eq "Host box6" "$(sed -n 3p "$config")" "the block's line with an Include loop"
assert_exit 0 add_host box6
assert_eq 1 "$(grep -c '^Host box6$' "$config")" "box6 blocks after a second run"

# A symlinked config stays a symlink, with the block written to the file it points to
printf 'Host *\n  ServerAliveInterval 60\n' > "$SANDBOX/real-config"
rm "$config"
ln -s "$SANDBOX/real-config" "$config"
assert_exit 0 add_host box4
[ -L "$config" ] || fail "add-host replaced the symlinked config"
assert_eq "Host box4" "$(head -n 1 "$SANDBOX/real-config")" "the first line of the linked config"
assert_file_contains "$SANDBOX/real-config" "Host *"
test_done
