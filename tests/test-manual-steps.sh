#!/bin/bash
# The checks run through replaced functions and stubs
# shellcheck disable=SC2329

# The manual steps: lib/manual.sh's list, which leaves out the steps done and renumbers the rest,
# its status, scripts/manual-steps-doc.sh keeping the READMEs in step with steps.sh, the
# manual-steps step's contract, and its checks.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script manual-steps/install.sh

# expect <status> <check...>: runs the check in this shell, unlike assert_exit, so the test can read
# the MANUAL_DETAIL and state it sets
expect() {
    local want="$1" got=0
    shift
    MANUAL_DETAIL=""
    "$@" > "$SANDBOX/check-output" 2>&1 || got=$?
    assert_eq "$want" "$got" "'$*' exit status"
}

# check_of <id>: the result in $SANDBOX/state/<id>, a 0, 1, or 2 and then a detail
mkdir -p "$SANDBOX/state"
check_of() {
    local result detail=""
    read -r result detail < "$SANDBOX/state/$1" || return 2
    MANUAL_DETAIL="$detail"
    return "$result"
}
set_state() {
    echo "$2" > "$SANDBOX/state/$1"
}

fixture_steps() {
    manual_reset
    manual_group macos "**One**"
    manual_step macos a --check "check_of a" "Step A" <<< "A, first."
    manual_step macos b <<'MD'
B, with more:
1. inner one
2. inner two

After the list.
MD
    manual_group macos "**Two**"
    manual_step macos c --check "check_of c" "Step C" <<< "C."
    manual_step macos d <<< "**D.**"
    manual_step macos d1 --parent d --bullet --check "check_of d1" "Step D1" <<< "D1."
    manual_step macos d2 --parent d --bullet --optional --check "check_of d2" "Step D2" <<< "D2."
    manual_group macos "When:"
    manual_step macos e --bullet --elsewhere --check "check_of e" "Step E" <<< "E."
    manual_step ubuntu a <<< "Ubuntu's A."
}

# Every step, as the README lists them
fixture_steps
# shellcheck disable=SC2034 # manual_markdown reads it
MANUAL_DONE=" "
assert_eq "**One**

1. A, first.
2. B, with more:
   1. inner one
   2. inner two

   After the list.

**Two**

3. C.
4. **D.**
   - D1.
   - D2.

When:

- E." "$(manual_markdown macos)" "the full list"
assert_eq "1. Ubuntu's A." "$(manual_markdown ubuntu)" "the other OS's list"

# A step done goes, the rest renumber, a step without a check goes once all under it have, and so
# does a group with no step left
set_state a 0
set_state c 1
set_state d1 0
set_state d2 0
set_state e 2
manual_evaluate macos
assert_eq "**One**

1. B, with more:
   1. inner one
   2. inner two

   After the list.

**Two**

2. C.

When:

- E." "$(manual_markdown macos)" "the list with A and D done"
set_state c 0
manual_evaluate macos
assert_eq "**One**

1. B, with more:
   1. inner one
   2. inner two

   After the list.

When:

- E." "$(manual_markdown macos)" "the list with group Two done"
manual_result macos c || fail "manual_result for a step done"
assert_exit 2 manual_result macos b

# Declaring a step wrong fails, saying why
bad_step() {
    manual_reset
    manual_step macos x <<< "X."
    "$@"
}
assert_exit 2 bad_step manual_step macos x <<< "Again."
assert_contains "$RUN_OUTPUT" "unique on its OS"
assert_exit 0 bad_step manual_step ubuntu x <<< "Same id, other OS."
assert_exit 2 bad_step manual_step macos y --parent nope <<< "Y."
assert_contains "$RUN_OUTPUT" "--parent nope isn't a step declared before it"
assert_exit 2 bad_step manual_step macos y --optional <<< "Y."
assert_contains "$RUN_OUTPUT" "--optional needs --check"
assert_exit 2 bad_step manual_step windows y <<< "Y."
assert_exit 2 bad_step manual_step macos y < /dev/null
assert_contains "$RUN_OUTPUT" "no markdown on stdin"

# Status reports each check but --elsewhere ones; an optional step not done is info
as_os macos
replace_fn manual_steps fixture_steps
set_state c 1
set_state d1 "2 it needs X"
set_state d2 1
set_state e 1
assert_exit 3 main --status
assert_eq "  ok         Step A
  missing    Step C
  unverified Step D1: it needs X
  info       Step D2: not done, which is optional
  info       Manual steps no script can check: bash setup.sh manual-steps lists them with the rest left to do" \
    "$RUN_OUTPUT" "status"
DOTFILES_STATUS_FOR_ALERTS=1 assert_exit 0 main --status
assert_eq "  skipped    Manual steps: skipped by --for-alerts, since they're to-dos rather than health" "$RUN_OUTPUT" \
    "status for alerts"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Remaining manual steps on macOS (README.md → Manual steps), leaving out the 1 done (--status lists them):"
assert_contains "$RUN_OUTPUT" "  1. B, with more:"
assert_not_contains "$RUN_OUTPUT" "A, first."
assert_not_contains "$RUN_OUTPUT" "**"
load_script manual-steps/install.sh

# Each check steps.sh names is a function install.sh defines
each_check_defined() {
    local step="$1" i fn
    load_script "$step/install.sh"
    manual_steps
    for ((i = 0; i < ${#MS_ID[@]}; i++)); do
        [ -n "${MS_CHECK[i]}" ] || continue
        fn="${MS_CHECK[i]%% *}"
        declare -F "$fn" > /dev/null || fail "$step/steps.sh names check $fn for ${MS_OS[i]} ${MS_ID[i]}, which isn't a function"
    done
}
each_check_defined manual-steps
each_check_defined ai_tools/manual-steps

# manual-steps-doc writes the READMEs' lists from steps.sh, and --check fails while they differ
doc_sync() {
    local copy="$SANDBOX/repo"
    mkdir -p "$copy/manual-steps" "$copy/ai_tools/manual-steps"
    cp -R "$REPO_DIR/lib" "$REPO_DIR/scripts" "$REPO_DIR/README.md" "$copy/"
    cp "$REPO_DIR/manual-steps/steps.sh" "$copy/manual-steps/"
    cp "$REPO_DIR/ai_tools/manual-steps/steps.sh" "$REPO_DIR/ai_tools/README.md" "$copy/ai_tools/"
    mv "$copy/ai_tools/steps.sh" "$copy/ai_tools/manual-steps/"
    assert_exit 0 bash "$copy/scripts/manual-steps-doc.sh" --check
    sed 's/^Turn on FileVault\.$/Turn on FileVault now./' "$copy/manual-steps/steps.sh" > "$SANDBOX/steps.sh"
    mv "$SANDBOX/steps.sh" "$copy/manual-steps/steps.sh"
    snapshot "$copy/README.md"
    assert_exit 1 bash "$copy/scripts/manual-steps-doc.sh" --check
    assert_contains "$RUN_OUTPUT" "README.md's Manual steps differ from manual-steps/steps.sh. Run just manual-steps-doc:"
    assert_unchanged "$copy/README.md" "after --check"
    assert_exit 0 bash "$copy/scripts/manual-steps-doc.sh"
    assert_contains "$RUN_OUTPUT" "README.md: wrote Manual steps from manual-steps/steps.sh"
    assert_file_contains "$copy/README.md" "21. Turn on FileVault now."
    assert_exit 0 bash "$copy/scripts/manual-steps-doc.sh" --check
    assert_exit 0 bash "$copy/scripts/manual-steps-doc.sh"
    assert_contains "$RUN_OUTPUT" "README.md: Manual steps already match manual-steps/steps.sh"
}
subtest doc_sync

# The step's contract: status only reads, and apply only prints, the same each run
contract() {
    local os cmd
    for cmd in sqlite3 plutil sfltool tmutil pro fdesetup tailscale gh lsblk nmcli gsettings gdbus busctl ss \
        systemctl dpkg-query getent; do
        stub "$cmd" 'exit 1'
    done
    stub_sudo_cacheable
    cache_sudo yes
    for os in macos ubuntu; do
        load_script manual-steps/install.sh
        as_os "$os"
        assert_read_only 3 main --status
        assert_contains "$RUN_OUTPUT" "missing "
        assert_idempotent main
        assert_contains "$RUN_OUTPUT" "Remaining manual steps on $(manual_os_name "$os")"
        assert_eq "" "$(machine_changes "$STUB_LOG")" "apply's changes on $os"
    done
}
subtest contract

# macOS's default browser: the http handler at an entry's own level, not in its nested dict
default_browser() {
    as_os macos
    mkdir -p "$(dirname "$LAUNCH_SERVICES_PREFS")"
    touch "$LAUNCH_SERVICES_PREFS"
    handlers() {
        printf '<array>\n\t<dict>\n\t\t<key>LSHandlerPreferredVersions</key>\n\t\t<dict>\n'
        printf '\t\t\t<key>LSHandlerRoleAll</key>\n\t\t\t<string>com.google.chrome</string>\n\t\t</dict>\n'
        printf '\t\t<key>LSHandlerRoleAll</key>\n\t\t<string>%s</string>\n' "$1"
        printf '\t\t<key>LSHandlerURLScheme</key>\n\t\t<string>http</string>\n\t</dict>\n</array>\n'
    }
    handlers com.apple.Safari > "$SANDBOX/handlers"
    stub plutil 'cat "$SANDBOX/handlers"'
    expect 1 chrome_default_browser
    assert_eq "com.apple.safari is" "$MANUAL_DETAIL" "the detail for Safari"
    handlers com.google.Chrome > "$SANDBOX/handlers"
    expect 0 chrome_default_browser
    stub plutil 'exit 1'
    expect 2 chrome_default_browser
    rm "$LAUNCH_SERVICES_PREFS"
    expect 1 chrome_default_browser
}
subtest default_browser

# Login items: only your records count, and a helper counts for its app
login_items() {
    local uid
    uid="$(id -u)"
    as_os macos
    stub_sudo_cacheable
    cat > "$SANDBOX/btm" <<BTM
========================
 Records for UID -2 : FFFF
========================
 #1:
                 Name: Rectangle
          Disposition: [enabled, allowed, visible, notified] (0xb)
           Identifier: 2.com.knollsoft.Rectangle
========================
 Records for UID $uid : 1234
========================
 #1:
                 Name: Rectangle
          Disposition: [disabled, allowed, visible, notified] (0xa)
           Identifier: 2.com.knollsoft.Rectangle
                  URL: file:///Applications/Rectangle.app/
 #2:
                 Name: Amphetamine Launcher
          Disposition: [enabled, allowed, visible, notified] (0xb)
           Identifier: 4.com.if.Amphetamine-Launcher
    Parent Identifier: 2.com.if.Amphetamine
BTM
    stub sfltool '[ "$*" == dumpbtm ] && cat "$SANDBOX/btm"'
    cache_sudo no
    expect 2 login_item_state com.knollsoft.Rectangle /Applications/Rectangle.app
    assert_contains "$MANUAL_DETAIL" "$ROOT_ONLY_TEXT"
    cache_sudo yes
    login_item_state com.knollsoft.Rectangle /Applications/Rectangle.app
    assert_eq disabled "$LOGIN_ITEM_STATE" "Rectangle's login item"
    login_item_state com.if.Amphetamine /Applications/Amphetamine.app
    assert_eq enabled "$LOGIN_ITEM_STATE" "Amphetamine's login item, by its helper"
    login_item_state com.sindresorhus.Dato /Applications/Dato.app
    assert_eq none "$LOGIN_ITEM_STATE" "Dato's login item"
    echo "nothing" > "$SANDBOX/btm"
    expect 2 login_item_state com.if.Amphetamine /Applications/Amphetamine.app
}
subtest login_items

# Privacy settings: system-wide ones need root, and an unreadable database can't tell
privacy() {
    as_os macos
    stub_sudo_cacheable
    cache_sudo no
    # shellcheck disable=SC2034 # tcc_query reads it
    TCC_SYSTEM_DB="$SANDBOX/TCC.db"
    stub sqlite3 'case "$*" in
    *kTCCServiceAccessibility*org.hammerspoon.Hammerspoon*) echo 2 ;;
    *kTCCServiceAccessibility*) echo 0 ;;
    *kTCCServiceAppleEvents*) [ -e "$SANDBOX/tcc-unreadable" ] && exit 1; printf "%s\n" "com.mitchellh.ghostty|2" "com.apple.finder|0" ;;
esac'
    expect 2 tcc_allowed kTCCServiceAccessibility org.hammerspoon.Hammerspoon
    assert_contains "$MANUAL_DETAIL" "$ROOT_ONLY_TEXT"
    cache_sudo yes
    expect 0 tcc_allowed kTCCServiceAccessibility org.hammerspoon.Hammerspoon
    expect 1 tcc_allowed kTCCServiceAccessibility com.knollsoft.Rectangle
    expect 1 tcc_allowed kTCCServiceAccessibility "x'; DROP TABLE access; --"
    expect 1 tcc_automation_allowed org.hammerspoon.Hammerspoon "${OPEN_IN_TARGETS[@]}"
    assert_eq "com.apple.finder, com.apple.systemevents, com.google.Chrome" "$MANUAL_DETAIL" "the targets not allowed"
    expect 0 tcc_automation_allowed org.hammerspoon.Hammerspoon com.mitchellh.ghostty
    touch "$SANDBOX/tcc-unreadable"
    expect 2 tcc_automation_allowed org.hammerspoon.Hammerspoon com.mitchellh.ghostty
    assert_eq "$TCC_NEEDS_ACCESS" "$MANUAL_DETAIL" "the detail without Full Disk Access"
}
subtest privacy

# Spotlight's privacy list holds each folder that exists, with or without the data volume's prefix
spotlight() {
    as_os macos
    stub_sudo_cacheable
    # shellcheck disable=SC2034 # spotlight_excluded reads it
    SPOTLIGHT_CONFIG="$SANDBOX/VolumeConfiguration.plist"
    cache_sudo yes
    mkdir -p "$HOME/Dev" "$HOME/go"
    echo "<array><string>/System/Volumes/Data$HOME/Dev</string></array>" > "$SANDBOX/exclusions"
    stub plutil 'cat "$SANDBOX/exclusions"'
    expect 1 spotlight_excluded
    # shellcheck disable=SC2088 # shown, not expanded
    assert_eq "~/go not excluded" "$MANUAL_DETAIL" "the folders not excluded"
    echo "<array><string>/System/Volumes/Data$HOME/Dev</string><string>$HOME/go/</string></array>" > "$SANDBOX/exclusions"
    expect 0 spotlight_excluded
    cache_sudo no
    expect 2 spotlight_excluded
}
subtest spotlight

# Tailscale: key expiry shows in Self.KeyExpiry, and the funnel attribute is fine while a funnel is up
tailscale_checks() {
    as_os ubuntu
    stub tailscale 'case "$*" in
    "status --json") cat "$SANDBOX/ts.json" ;;
    "funnel status --json") cat "$SANDBOX/funnel.json" ;;
    *) exit 1 ;;
esac'
    echo '{"BackendState":"Running","Self":{"KeyExpiry":"2027-01-01T00:00:00Z","CapMap":{"funnel":null}}}' > "$SANDBOX/ts.json"
    echo '{}' > "$SANDBOX/funnel.json"
    expect 1 tailscale_key_never_expires
    assert_eq "the machine's key expires 2027-01-01T00:00:00Z" "$MANUAL_DETAIL" "the key expiry detail"
    expect 1 tailscale_funnel_attr_gone
    echo '{"AllowFunnel":{"host:443":true}}' > "$SANDBOX/funnel.json"
    expect 0 tailscale_funnel_attr_gone
    echo '{"BackendState":"Running","Self":{"KeyExpiry":null,"CapMap":{}}}' > "$SANDBOX/ts.json"
    expect 0 tailscale_key_never_expires
    expect 0 tailscale_funnel_attr_gone
    echo '{"BackendState":"NeedsLogin"}' > "$SANDBOX/ts.json"
    expect 2 tailscale_key_never_expires
    expect 1 tailscale_connected
}
subtest tailscale_checks

# The display scale comes from Mutter's logical monitors
display_scale() {
    as_os ubuntu
    gdbus_state() {
        printf "(uint32 1, [(('DP-1', 'DEL', 'U2723QE', 'x'), [('3840x2160@60.000', 3840, 2160, 60.0, 2.0, [1.0, 2.0], {})], {})], "
        printf "[(0, 0, %s, uint32 0, true, [('DP-1', 'DEL', 'U2723QE', 'x')], @a{sv} {})], {})\n" "$1"
    }
    gdbus_state 1.5 > "$SANDBOX/gdbus"
    stub gdbus 'cat "$SANDBOX/gdbus"'
    expect 1 display_scale_200
    assert_eq "scale 1.5" "$MANUAL_DETAIL" "the scale detail"
    gdbus_state 2.0 > "$SANDBOX/gdbus"
    expect 0 display_scale_200
    stub gdbus 'exit 1'
    expect 2 display_scale_200
    hide gnome-shell
    expect 0 display_scale_200
}
subtest display_scale

# A desktop session after a reboot: GDM's automatic login in its daemon section, or Remote Login
desktop_session() {
    as_os ubuntu
    GDM_CONF="$SANDBOX/custom.conf"
    printf '%s\n' "[daemon]" "# AutomaticLoginEnable = true" "[security]" "AutomaticLoginEnable = true" > "$GDM_CONF"
    stub systemctl 'echo disabled'
    stub ss
    expect 1 desktop_session_after_reboot
    printf '%s\n' "[daemon]" "AutomaticLoginEnable = True" > "$GDM_CONF"
    expect 0 desktop_session_after_reboot
    assert_eq "GDM logs you in" "$MANUAL_DETAIL" "the GDM detail"
    rm "$GDM_CONF"
    stub systemctl '[ "$*" == "is-enabled gnome-remote-desktop.service" ] && echo enabled'
    expect 1 desktop_session_after_reboot
    stub ss 'echo "LISTEN 0 10 *:3389 *:*"'
    expect 0 desktop_session_after_reboot
    assert_eq "Remote Login is on" "$MANUAL_DETAIL" "the Remote Login detail"
}
subtest desktop_session

# The recovery key matters only on an encrypted disk
recovery_key() {
    stub lsblk 'printf "%s\n" disk part'
    expect 0 disk_recovery_key_kept
    assert_eq "the disk isn't encrypted" "$MANUAL_DETAIL" "the detail without encryption"
    stub lsblk 'printf "%s\n" disk part crypt'
    expect 2 disk_recovery_key_kept
    stub lsblk 'exit 1'
    expect 2 disk_recovery_key_kept
}
subtest recovery_key

# Signing: git signs with an SSH key, and GitHub lists it as a signing key
signing() {
    local key="$HOME/.ssh/id_ed25519_signing.pub"
    stub gh 'exit 1'
    expect 1 git_signing_done
    assert_eq "git doesn't sign commits with an SSH key yet" "$MANUAL_DETAIL" "the detail without signing"
    mkdir -p "$HOME/.ssh"
    echo "ssh-ed25519 AAAAmine me@example.com" > "$key"
    git config --file "$HOME/.gitconfig" gpg.format ssh
    git config --file "$HOME/.gitconfig" commit.gpgsign true
    # shellcheck disable=SC2088 # git's config holds the literal ~/
    git config --file "$HOME/.gitconfig" user.signingkey "~/.ssh/id_ed25519_signing.pub"
    expect 2 git_signing_done
    stub gh '[ "$*" == "api user/ssh_signing_keys --jq .[].key" ] && echo "ssh-ed25519 AAAAother"'
    expect 1 git_signing_done
    assert_contains "$MANUAL_DETAIL" "GitHub doesn't list ~/.ssh/id_ed25519_signing.pub as a signing key"
    stub gh 'printf "%s\n" "ssh-ed25519 AAAAother" "ssh-ed25519 AAAAmine"'
    expect 0 git_signing_done
}
subtest signing

# Solaar lists the devices it has seen
solaar() {
    as_os ubuntu
    expect 1 solaar_paired
    mkdir -p "$(dirname "$SOLAAR_CONFIG")"
    printf '%s\n' "- 1.1.20" "- _NAME: MX Master 4" "  _modelId: x" > "$SOLAAR_CONFIG"
    expect 0 solaar_paired
}
subtest solaar
test_done
