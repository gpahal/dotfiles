# The setup steps scripts can't do, as README.md's "Manual steps" lists them: the list
# scripts/manual-steps-doc.sh writes there, and the checks manual-steps/install.sh runs. lib/manual.sh
# says how to declare one; the checks are functions in install.sh. Source it; don't run it.
# shellcheck shell=bash

# shellcheck disable=SC2034 # lib/manual.sh reads it
MANUAL_DOC="$DOTFILES_DIR/README.md"

manual_steps() {
    manual_reset

    manual_group macos "**Permissions**"
    manual_step macos full-disk-access --check ghostty_full_disk_access "Ghostty has Full Disk Access" <<'MD'
Give Ghostty Full Disk Access in **System Settings → Privacy & Security → Full Disk Access**, reopen it, and run `bash setup.sh macos` in the repo again. Do the rest from Ghostty.
MD
    manual_step macos ghostty-notifications \
        --check ghostty_notifications "Ghostty's notifications allowed, with the Persistent style" <<'MD'
Allow Ghostty's notifications, with step 1 of [Ghostty notifications](#ghostty-notifications).
MD
    manual_step macos ghostty-focus <<'MD'
Add Ghostty to any Focus mode's **Allowed Apps**.
MD
    manual_step macos ghostty-accessibility --check ghostty_accessibility "Ghostty has Accessibility" <<'MD'
Add Ghostty in **System Settings → Privacy & Security → Accessibility**.
MD

    manual_group macos "**Apps**"
    manual_step macos chrome-default-browser \
        --check chrome_default_browser "Google Chrome is the default browser" <<'MD'
Set Google Chrome as the default browser.
MD
    manual_step macos logi-options <<'MD'
Open Logi Options+, grant its permissions, and pair your devices.
MD
    manual_step macos orbstack --check orbstack_set_up "OrbStack set up" <<'MD'
Open OrbStack once and finish its setup.
MD
    manual_step macos vicinae --check vicinae_set_up "Vicinae has Accessibility and opens at login" <<'MD'
Open Vicinae and finish its onboarding. Grant Accessibility, which paste and snippets need, and keep Launch at login on. Full Disk Access is optional; file search needs it to cover every folder.
MD
    manual_step macos rectangle --check rectangle_set_up "Rectangle has Accessibility" <<'MD'
Open Rectangle, grant accessibility, and set your shortcuts.
MD
    manual_step macos login-items \
        --check login_items_on "Rectangle, Amphetamine, Tailscale, and Dato open at login" <<'MD'
Turn on Launch at login in Rectangle, Amphetamine, Tailscale, and Dato.
MD
    manual_step macos app-extras <<'MD'
Optional: turn on AppCleaner's SmartDelete, and install [Supercharge](https://sindresorhus.gumroad.com/l/supercharge).
MD
    manual_step macos stream-deck \
        --check stream_deck_set_up "Stream Deck's profiles, Accessibility, and Apple events allowed" <<'MD'
Open Stream Deck and accept its prompt to install the **Main** profile. Press **Overview** and accept the prompt for the **System** profile. Press **Editor**, **Terminal**, and **Files** with Ghostty, Zed, and Finder in front, then **New Tab** and **Gmail**, and **Allow** each prompt. Add Elgato Stream Deck in **Privacy & Security → Accessibility**.
MD
    manual_step macos hammerspoon \
        --check hammerspoon_set_up "Hammerspoon's Accessibility and Apple events allowed" <<'MD'
Open Hammerspoon and add it in **Privacy & Security → Accessibility**. Press `Ctrl+Opt+Cmd+T` and `E` with Ghostty, Zed, and Finder in front, then `N`, and **Allow** each prompt.
MD
    manual_step macos monitor-input --optional --check monitor_input_on "Monitor input switching on" <<'MD'
Optional: set up [monitor input](#monitor-input) switching on the Mac and on Ubuntu.
MD

    manual_group macos "**Accounts and keys**"
    manual_step macos tailscale-login --check mac_tailscale_signed_in "Signed in to Tailscale" <<'MD'
Sign in to Tailscale with the account your Ubuntu machine and phone use.
MD
    manual_step macos google-account \
        --check google_account_added "A Google account in Internet Accounts, for Calendar and Contacts" <<'MD'
Add your Google account to Calendar and Contacts.
MD
    manual_step macos chrome-sites <<'MD'
In Chrome, sign in to the sites you want agents to use.
MD
    manual_step macos github-login --elsewhere --check github_logged_in "Logged in to GitHub with gh" <<'MD'
If you skipped the GitHub login, re-run `bash setup.sh git` from a terminal and accept it.
MD
    manual_step macos git-signing --check git_signing_done "Commits signed with a key GitHub lists" <<'MD'
Run `just git-signing` and the `gh` commands it prints.
MD

    manual_group macos "**Security and backups**"
    manual_step macos touch-id --elsewhere --check touch_id_on "Touch ID for sudo" <<'MD'
Optional: `just touch-id`.
MD
    manual_step macos filevault --elsewhere --check filevault_on "FileVault on" <<'MD'
Turn on FileVault.
MD
    manual_step macos backups --check time_machine_backed_up "Backed up off the machine" <<'MD'
Back up off the Mac, such as with Time Machine.
MD
    manual_step macos restore <<'MD'
Restore a file from the backup once, to check it.
MD

    manual_group macos "**Performance and privacy**"
    manual_step macos spotlight-privacy \
        --check spotlight_excluded "Spotlight skips ~/Dev, ~/go, and ~/Library/pnpm" <<'MD'
In **System Settings → Spotlight → Search Privacy…**, add `~/Dev`, `~/go`, and `~/Library/pnpm`, so Spotlight stops indexing builds and package stores. Press `Cmd+Shift+G` in the file picker to type a path.
MD
    manual_step macos spotlight-clipboard <<'MD'
In **System Settings → Spotlight**, turn off the clipboard history, or keep it for the shortest time offered. It keeps copied passwords.
MD
    manual_step macos apple-intelligence <<'MD'
Optional: if you don't use Apple Intelligence, turn it off. Search System Settings for **Apple Intelligence**.
MD
    manual_step macos chrome-memory-saver --check chrome_memory_saver_on "Chrome's Memory Saver on" <<'MD'
In Chrome, turn on **Memory Saver** in `chrome://settings/performance`.
MD

    manual_group ubuntu "Once:"
    manual_step ubuntu bios <<'MD'
**BIOS/UEFI.** Set the power-loss setting to **Power On**. For Wake-on-LAN, turn it on and turn **ErP**/**EuP** off.
MD
    manual_step ubuntu network --elsewhere --check network_ready "Wi-Fi connects at boot, or Ethernet" <<'MD'
**Network.** Use Ethernet, or run the `nmcli` commands the `ubuntu` step prints so Wi-Fi connects at boot.
MD
    manual_step ubuntu disk-recovery-key \
        --check disk_recovery_key_kept "Disk encryption's recovery key kept off the machine" <<'MD'
**Disk encryption.** Store the recovery key off the machine.
MD
    manual_step ubuntu login-shell --elsewhere --check login_shell_zsh "zsh as the login shell" <<'MD'
**Login shell.** `chsh -s /usr/bin/zsh`, if you skipped it.
MD
    manual_step ubuntu tailscale <<'MD'
**Tailscale.**
MD
    manual_step ubuntu tailscale-up --parent tailscale --bullet --elsewhere \
        --check tailscale_connected "Tailscale connected" <<'MD'
Run `sudo tailscale up`.
MD
    manual_step ubuntu tailscale-key-expiry --parent tailscale --bullet \
        --check tailscale_key_never_expires "Tailscale key expiry off for this machine" <<'MD'
In the admin console, disable key expiry for the machine.
MD
    manual_step ubuntu tailscale-policy --parent tailscale --bullet <<'MD'
Limit the access policy, and remove `root` from `users` in its `ssh` rules.
MD
    manual_step ubuntu tailscale-funnel --parent tailscale --bullet --optional \
        --check tailscale_funnel_attr_gone "No funnel nodeAttr for this machine, unless you use funnels" <<'MD'
Remove the `funnel` nodeAttr, unless you use it.
MD
    manual_step ubuntu ssh-key --elsewhere --check ssh_key_only "SSH password logins off, after a key login" <<'MD'
**SSH key.** On the Mac:
1. `ssh-keygen -t ed25519`, if there's no `~/.ssh/id_ed25519`.
2. `just ssh-host <alias> <machine-name>`, using the machine's name in Tailscale. Leave out `<machine-name>` if it matches the alias. With MagicDNS off, use the full `<machine-name>.<tailnet>.ts.net` name.
3. `ssh-copy-id <alias>`.
4. `ssh -O exit <alias>`.

Then SSH in with the key and re-run `bash setup.sh ubuntu`, which turns off password logins and finishes the Tailscale setup. Before closing that session, check `ssh -S none <alias> true` from the Mac.
MD
    manual_step ubuntu github-login --elsewhere --check github_logged_in "Logged in to GitHub with gh" <<'MD'
**GitHub.** If you skipped the login, re-run `bash setup.sh git` from a terminal and accept it.
MD
    manual_step ubuntu git-signing --check git_signing_done "Commits signed with a key GitHub lists" <<'MD'
**Commit signing.** Run `just git-signing` and the `gh` commands it prints.
MD
    manual_step ubuntu solaar --check solaar_paired "Logitech devices paired in Solaar" <<'MD'
**Logitech.** At the desktop, open Solaar and pair your devices.
MD
    manual_step ubuntu gnome-extensions --elsewhere \
        --check gnome_extensions_loaded "GNOME loaded the Stream Deck and Vicinae extensions" <<'MD'
**GNOME extensions.** Log out of the desktop and back in once, so GNOME loads the extensions the `stream-deck` and `vicinae` steps turned on.
MD
    manual_step ubuntu monitor-input --optional --check monitor_input_on "Monitor input switching on" <<'MD'
**Monitor input (optional).** Set up [monitor input](#monitor-input) switching here and on the Mac.
MD
    manual_step ubuntu desktop-session --check desktop_session_after_reboot \
        "A desktop session after a reboot, through GDM's automatic login or Remote Login" <<'MD'
**Desktop session after a reboot.** Solaar and Claude in Chrome need one. Turn on Remote Login in **Settings → System → Remote Desktop** and connect over Tailscale with Windows App, or turn on GDM automatic login (the keyring stays locked).
MD
    manual_step ubuntu phone-alerts --elsewhere --check phone_alerts_set "ntfy URL for phone alerts set" <<'MD'
**Phone alerts.** Run `just alerts` and leave the topic empty to generate one. On Android, scan the first QR code it shows, which the ntfy app opens; on an iPhone, scan the second. Then run `just alerts test`. To use your own topic of 20 or more characters, paste it or its `https://` URL instead.
MD
    manual_step ubuntu power-cuts <<'MD'
**Power cuts.** Plug in the UPS over USB and re-run `bash setup.sh ubuntu`. Then:
1. Unplug the UPS from the wall and wait for the push, the shutdown, and the UPS cutting its output (`sudo upsmon -c fsd` shuts down at once). If the output stays on, find the UPS setting that cuts it on shutdown.
2. Plug it back in, and check the machine starts and `just status` shows the UPS on mains.
3. At the machine, `sudo rtcwake -m off -s 120` starts it 2 minutes later. If it doesn't, only the BIOS setting brings it back.
4. Run `just alerts test` again.
MD
    manual_step ubuntu backups --check deja_dup_backed_up "Backed up off the machine" <<'MD'
**Backups.** Back up `~` and `/var/lib/docker/volumes` off the machine on a schedule, such as with Déjà Dup.
MD
    manual_step ubuntu restore <<'MD'
**Restore.** Restore a few files from the backup once, to check it.
MD
    manual_step ubuntu livepatch --optional --check livepatch_on "Livepatch on" <<'MD'
**Livepatch (optional).** `sudo pro attach <token>`, then `sudo pro enable livepatch`.
MD
    manual_step ubuntu display-scale --check display_scale_167 "Display scale 167%" <<'MD'
**Display scale.** In **Settings → Displays**, set **Scale** to **167%**, between 150% and 200%.
MD

    manual_group ubuntu "When needed:"
    manual_step ubuntu reboot --bullet --elsewhere --check no_reboot_pending "No reboot pending" <<'MD'
Reboot when `just status` says one is pending.
MD
    manual_step ubuntu firmware --bullet <<'MD'
Install firmware updates it lists: `fwupdmgr refresh && fwupdmgr update`.
MD
    manual_step ubuntu firmware-timeout --bullet <<'MD'
If `fwupdmgr refresh` times out, run `curl -sSI --max-time 15 https://cdn.fwupd.org/downloads/firmware.xml.zst.jcat` and `curl -sSI --max-time 15 https://fwupd.org`. When only the first fails, your network blocks the firmware CDN. Refresh on another network, such as a phone hotspot, or through a Tailscale exit node.
MD
    manual_step ubuntu release-upgrade --bullet <<'MD'
After a release upgrade, re-run `bash setup.sh` and `bash ai_tools/setup.sh`.
MD
}
