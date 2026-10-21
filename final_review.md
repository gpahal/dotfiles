# Final review

Repository: dotfiles at `117b3231d180ca9c9711bfb693e4af2e5084eaa6` ("Retry monitor input switches until confirmed (#31)"), reviewed 2026-10-21. The worktree was clean and matched `main`, so both reviews looked at existing code, not a branch diff.

This file merges two independent reviews:

- **Claude** reviewed the latest commit (#31): the monitor-input retry loop and the move to Solaar from the Solaar team's PPA.
- **Codex** ([codex_review.md](codex_review.md)) did a low-effort pass over the whole repository: 103 operational files, about 15,800 lines.

No finding appeared in both reviews. The only shared area is monitor-input, where each review found a different problem in a different file (findings 4 and 7). Claude checked every Codex finding against the code before merging it. The **Verified** line under each finding says how.

**Verdict: changes needed, now fixed (see Resolution).** Six findings were P2 and three were P3. Neither review found a security vulnerability in the paths it covered.

## Summary

| # | Severity | Area | Finding | Source |
| :- | :- | :- | :- | :- |
| 1 | P2 | `ubuntu/lib/ups.sh:286` | A failing UPS scan reports "no UPS found" and succeeds | Codex |
| 2 | P2 | `ubuntu/lib/updates.sh:64` | Merging auto-upgrade settings drops other APT statements on the same line | Codex |
| 3 | P2 | `ai_tools/t3-code/install.sh:646` | A fresh T3 service install can pass with no server running | Codex |
| 4 | P2 | `monitor-input/dotfiles-monitor-input:77` | Switching to the Mac can report failure when it worked | Claude |
| 5 | P2 | `hotkeys/install.sh:106` | Shortcuts are written when `open-in` is missing | Codex |
| 6 | P2 | `stream-deck/build-profile.sh:8` | A relative output path builds into the temp dir, which then gets deleted | Codex |
| 7 | P3 | `monitor-input/setup.sh:88` | Input codes with leading zeros are read as octal | Codex |
| 8 | P3 | `logitech/install.sh:111` | `curl` and `gpg` are required even when nothing needs them | Claude |
| 9 | P3 | `monitor-input/dotfiles-monitor-input:17` | Failed switches take up to 15–30 s | Claude |

## Resolution

All nine findings are fixed in the working tree, uncommitted. Each fix has a test that fails on the old code and passes now. `just check` passes, and `just test` gives 100 passed, 0 failed, 1 skipped (`test-hammerspoon.sh`, no Lua).

| # | Fix | Test |
| :- | :- | :- |
| 1 | `setup_ups` captures nut-scanner's exit status and stderr. A non-zero exit prints both and fails. A clean exit with no device still prints "No UPS found". NUT 2.8.4's `main()` returns `EXIT_SUCCESS` whether or not it finds a device, and prints library warnings on stderr even then, so only the exit status counts. | `tests/test-ubuntu-ups.sh`: the scanner exits 42, so the step fails and shows stderr, writes no config, and leaves no temp file |
| 2 | `merged_auto_upgrades` splits lines at `;` outside quotes and comments, and replaces only our statements, keeping the others, the indentation, and trailing comments. Lines it can't split safely (scopes, statements spanning lines, `/* */` with a statement, `#clear`, `#include`) stay as they are, and our keys are appended after them, so apt's later-wins rule applies. Running it again changes nothing. | `tests/test-ubuntu-system.sh`: two statements on a line, ours second, `;` inside quotes, an unrelated line, scopes and comments, a statement over two lines. Run with mawk and busybox awk |
| 3 | A new helper, `restart_t3_code_service_serving_nothing`, holds the check, restart, and recheck. Both the first-install branch and the existing-unit branch call it. | `tests/test-t3-service.sh`: a first install with an idle launcher gets restarted, and one that stays idle fails |
| 4 | When switching away, a read-back that fails after a successful `setvcp` counts as switched. Switching here, an unreadable input still means the command was missed, so the script retries. | `tests/test-monitor-input.sh`: a monitor stub that answers reads only while showing this machine |
| 5 | `apply` fails before writing anything when `$OPEN_IN` isn't executable, and points to `bash setup.sh stream-deck`. | `tests/test-hotkeys.sh`: no `open-in` gives exit 1 and no `gsettings set` |
| 6 | `OUT` becomes an absolute path, and the zip is built in the temp dir and moved over `OUT` only on success. | `tests/test-stream-deck.sh`: a relative path from another directory produces the same profile |
| 7 | Decimal codes are evaluated as `$((10#…))`. `0x` hex is unchanged. | `tests/test-monitor-input.sh`: `017` → 17, `08` → 8, and out-of-range or malformed codes are rejected |
| 8 | `curl` is required only when the PPA source is missing, and `gpg` only when the PPA is about to be added. | `tests/test-logitech.sh`: with no `gpg`, the step fails before writing the pin. With everything applied, it needs neither. Ubuntu's Solaar installs without `gpg` |
| 9 | No separate change. With finding 4 fixed, a switch to the Mac on a monitor that stops answering takes one try, so the 5 × 2 s retries only happen on real failures, where they're the point. | Covered by finding 4's test (one `setvcp`) |

Not verified: BSD awk (finding 2) and Bash 3.2, because neither is installed here, and real hardware for findings 1 and 4.

## P2 findings

### 1. A failing UPS scan reports "no UPS found" and succeeds

`ubuntu/lib/ups.sh:286–289`

```bash
scan="$(sudo nut-scanner -U -q 2>/dev/null | ups_scan_parse)" || true
if [ -z "$scan" ]; then
    echo "  No UPS found on USB. Plug in the UPS's USB cable and re-run the step."
    return 0
```

`2>/dev/null` throws away `nut-scanner`'s stderr, and `|| true` throws away its exit status, even under `pipefail`. If the scanner itself fails (missing permission, broken install, driver error), the step says no UPS is plugged in and returns success. UPS monitoring stays unconfigured, so the machine won't shut down cleanly on power loss, and nothing reports it. This can happen even when USB detection found a UPS earlier.

- **Reproduced (Codex):** a `nut-scanner` stub that exits 42 with no output led to the "No UPS found" message and a successful step.
- **Verified (Claude):** read the code. `|| true` hides the status, and stderr is never shown.
- **Fix:** capture the scanner's status and stderr separately from the parse. When the scanner fails, print its error and return 1. Keep the "No UPS found" message for a scan that succeeds and finds nothing. Add a test for each case.

### 2. Merging auto-upgrade settings drops other APT statements on the same line

`ubuntu/lib/updates.sh:64–89` (`merged_auto_upgrades`)

The awk merger takes the first token of each line as its key, and on a match it replaces the **whole line**. APT allows several statements on one line, so with:

```
APT::Periodic::Enable "0"; APT::Periodic::AutocleanInterval "7";
```

the line becomes just the `Enable` setting, and `AutocleanInterval "7"` disappears. `apt-config` accepts the original line. Software & Updates or a user can write files like this, and the function's own comment says it keeps such settings. It breaks AGENTS.md's rule: "keep user edits to files the step merges into."

- **Reproduced (Codex):** ran the merger on the line above, and the second statement was lost.
- **Verified (Claude):** read the code. `key_of` returns the first token, and a match prints `want[i]` in place of the whole line.
- **Fix:** split lines on `;` and replace only the matching statement, or refuse to write when a line holds more than one statement and say why. Add the line above as a test case.

### 3. A fresh T3 service install can pass with no server running

`ai_tools/t3-code/install.sh:646–648`

```bash
"$HOME/.local/bin/t3" service install || true
wait_for_t3_code_service || return 1
echo "  Installed the T3 Code service, which starts at boot"
```

`wait_for_t3_code_service` only checks that the launcher is active with a stable MainPID. In T3 0.1.0 the server exits when another process holds `~/.t3/userdata`, such as a T3 started by hand, and the launcher keeps idling. The existing-unit branch (lines 666–677) catches this with `t3_code_service_serving_nothing`, restarts, and fails if it's still empty. The first-install branch skips that check. First install is when a hand-started T3 is most likely to hold the lock.

- **Reproduced (Codex):** an active, stable launcher with no child and no listening socket passed the first-install path.
- **Verified (Claude):** read both branches. Only the existing-unit branch calls `t3_code_service_serving_nothing`.
- **Fix:** run the same serving-nothing check and restart after the first install as well, preferably through one shared helper so the two branches can't drift apart again.

### 4. Switching to the Mac can report failure when it worked

`monitor-input/dotfiles-monitor-input:77–90` (new in #31)

After each `setvcp`, the loop reads the input back with `getvcp` and retries until it matches. #31 removed this comment: *"--noverify: reading the input back can fail once the monitor shows the other machine."* Many monitors stop answering DDC/CI on an input that isn't showing. On such a monitor, every switch **to the Mac**:

1. switches correctly,
2. fails the read-back, which counts as "unreadable",
3. sends `setvcp` four more times, waiting between tries,
4. prints "The monitor didn't switch to input 27 after 5 tries" and exits 1, so the unit fails.

The extra commands do no harm, but the journal fills with false errors and the unit's failed state hides real ones. The tests miss this because their `ddcutil` stub always answers `getvcp`.

- **Reproduced (Claude):** a `ddcutil` stub that answers `getvcp` only while showing this machine's input (17). Switching away to 27 left the monitor on 27, as intended, but the script ran 5 `setvcp`/`getvcp` pairs, printed the failure message, and exited 1.
- **Caveat:** if this monitor does answer DDC while showing the Mac, the finding doesn't apply. The removed comment suggests it doesn't.
- **Fix:** verify only when the target is this machine's input, where read-back works. Or treat an unreadable result as success when the target is the other machine. Add a test using a stub that can't be read while showing the other machine.

### 5. Shortcuts are written when `open-in` is missing

`hotkeys/install.sh:106–122`

Every shortcut runs `$OPEN_IN` (`~/.local/share/dotfiles/stream-deck/bin/open-in`), which the `stream-deck` step installs. `STEP_NEEDS="stream-deck"` only skips this step when `stream-deck` failed earlier in the same run. It doesn't check that `open-in` exists. So `bash setup.sh hotkeys` on its own, before `stream-deck` has ever run, writes all the GNOME shortcuts and says they open apps, but every one of them does nothing. This breaks AGENTS.md's rule: "A missing prerequisite fails the step before it changes anything."

- **Reproduced (Codex):** with no `open-in` present, `apply` wrote the shortcuts and reported success.
- **Verified (Claude):** read the code. `apply` checks only `gsettings`.
- **Fix:** before writing anything, check that `$OPEN_IN` is executable. If it isn't, fail and point to `bash setup.sh stream-deck`. `status` should report it missing too.

### 6. A relative output path builds into the temp dir, which then gets deleted

`stream-deck/build-profile.sh:8, 18, 23`

`OUT` comes from `$1` as given. `rm -f "$OUT"` resolves it from the caller's directory, but `zip` runs inside `(cd "$tmp" && …)`, so a relative path such as `./review.streamDeckProfile` writes the zip into `$tmp`, which the EXIT trap deletes. The script prints "Built ./review.streamDeckProfile" and exits 0, but no file exists, and any earlier file at that path is gone.

- **Reproduced (Codex):** exit 0 and a "Built" message, with no output file left.
- **Verified (Claude):** read the code. The `rm` and the `zip` resolve `OUT` from different directories.
- **Fix:** turn `OUT` into an absolute path right after line 8. Better still, build into a temp file and `mv` it over `OUT` only once `zip` succeeds, so a failed build never deletes the old profile. The default path is already absolute, so only a relative argument hits this.

## P3 findings

### 7. Input codes with leading zeros are read as octal

`monitor-input/setup.sh:85–91` (`input_code`)

The pattern accepts `[0-9]{1,3}`, and then `code=$(($1))` evaluates it. Bash reads a leading `0` as octal:

| Input | Result |
| :- | :- |
| `017` | 15 (DisplayPort 1, not HDMI 1) |
| `027` | 23 |
| `08` | `value too great for base` from bash, then the generic "should be a code from 1 to 255" message |

The help text lists the codes in decimal, so `017` reasonably means 17. Instead the monitor gets set to a different input.

- **Reproduced (Codex):** `017` → 15 and `027` → 23.
- **Reproduced (Claude):** the same results, plus the raw bash error for `08`.
- **Fix:** keep the `0x` branch and evaluate decimals as `$((10#$1))`, or reject leading zeros with a clear message. Add `017` and `08` to `tests/test-monitor-input.sh`.

### 8. `curl` and `gpg` are required even when nothing needs them

`logitech/install.sh:111–113` (new in #31)

`apply` runs `require_cmd curl` and `require_cmd gpg` before checking what's pending. So it fails even when everything is already set up, and when the PPA hasn't published for the release, where only `curl` is needed. Both come with Ubuntu desktop, so this only affects minimal installs. Moving the `gpg` check to just before `add_solaar_repo` would fix it, and `add_apt_repo` already checks for `gpg` itself.

### 9. Failed switches take up to 15–30 s

`monitor-input/dotfiles-monitor-input:17–18`

Five tries with a 2 s `VERIFY_DELAY` each, plus `ddcutil`'s own retries on a failed read, can stretch a failed switch to 15–30 s. A newer udev event restarts the unit and a oneshot unit has no start timeout, so nothing breaks. It only matters together with finding 4, where every switch to the Mac takes this long. Fixing finding 4 removes most of the cost.

## Checked and found sound

- **Solaar PPA trust (#31).** The key is pinned by its full fingerprint and fetched over HTTPS, and `add_apt_repo` refuses a key with a different fingerprint. `Signed-By` limits the key to this one source. Claude checked live: the keyserver's key has fingerprint `643FF34AF9151DC814DD3A1B2303D595EE907473` (UID "Launchpad PPA for Solaar").
- **Solaar apt pin (#31).** The Origin `LP-PPA-solaar-unifying-stable` matches the PPA's live `resolute` Release file. The `Package: *` / `-1` entry plus the specific `solaar` / `500` entry works as the comment says, because apt applies a package-specific pin over the general one. The PPA currently ships only `solaar` 1.1.20+202607061356~ubuntu26.04.1, and all of its dependencies come from Ubuntu.
- **Solaar version check (#31).** `solaar_version` gets `1.1.20` from the full version string, and `version_at_least` compares it correctly. The pin is written before the source, so apt never sees the PPA unpinned. The fallback to Ubuntu's Solaar when the PPA hasn't published is tested.
- **Monitor read-back parsing (#31).** `current_input` matches ddcutil's `--brief` output (`VCP 60 SNC x11`) and converts it to decimal. The config's `input` and `other` are always decimal because `input_code` normalizes them, so the comparison with `target` is sound (apart from finding 7).
- **Security.** Neither review found a vulnerability in the paths it covered. Adding a PPA lets that PPA's `solaar` maintainer scripts run as root. That's inherent to using a PPA, and the pin limits it to the one package.

Codex raised two more candidates and dropped them, because tests show the behavior is intentional.

## Testing

| Check | Claude | Codex |
| :- | :- | :- |
| `just check` | Passed (exit 0, no output) | Passed with `just --tempdir /tmp check`, since the sandbox's `/run/user/1000` is read-only |
| `just test` | 100 passed, 0 failed, 1 skipped | 100 passed, 0 failed, 1 skipped, after a rerun outside the sandbox with the installed Node on `PATH`. The first run had 9 failures from the environment (tmux sockets, `/var/tmp`, group changes, the mise shim going online) |
| `just test logitech monitor-input` | 2 passed | n/a |
| Targeted reproductions | Findings 4 and 7, and live PPA Release, Packages, and key checks | Findings 1–3 and 5–7, using disposable files and the test sandbox helpers |

Neither review changed production code or tests. Codex added `codex_review.md`, and this review adds `final_review.md`.

## Gaps

- `test-hammerspoon.sh` was skipped because Lua isn't installed. `test-diagnostics-macos.sh`, `test-touch-id.sh`, and `test-stream-deck-open-in.sh` don't run on Linux.
- Tests ran under Bash 5.3.9. Native Bash 3.2 wasn't run, though `just check`'s compatibility checks passed.
- Nobody tested real macOS behavior or real hardware: the monitor's DDC behavior (which decides whether finding 4 applies), the UPS, the Stream Deck, or the Logitech receiver.
- Nobody ran full machine provisioning (`just test-ubuntu`) or dependency vulnerability scans.
- The Codex pass was low-effort over the whole repository. Generated assets, vendored code, lockfile contents, and skill prose weren't reviewed.
