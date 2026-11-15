# Changelog

## 1.2.0 (2026-11-15)

- **Double-click setup:** `Setup.cmd` opens a guided menu. It checks Tailscale (and offers to install it), lets you pick the work folder in a folder window, and runs the install. Run it again later to invite or accept machines, check, reconnect AI tools or turn on hooks. It stops with a plain message if your organisation controls which scripts may run.
- **Invite codes:** pairing no longer needs Device IDs and IPs copied by hand. `invite.ps1` shows one code (`AIB1-...`) and the same code as a QR; the new machine joins with `install.ps1 -Invite <code>`, and `accept.ps1` on the inviting machine adds it after you confirm its name. Codes are checked for typos and for the right kit.
- **macOS (experimental):** `tools/mac/brain.py` installs, invites, accepts, checks and connects AI tools on a Mac. It downloads the official Syncthing release, verifies its checksum and checks that the file it keeps is a macOS program. Tested on a MacBook (Apple silicon, macOS 15) joined to a Windows machine.
- A join that stopped part-way can now be run again: the files the installer itself writes into the vault no longer count as "vault not empty".

## 1.1.1 (2026-11-15)

Fixes found by installing the kit on a clean Windows machine (Windows Sandbox).

- `install.ps1` and `register-hooks.ps1` install Syncthing and Python from the `winget` source only, so a missing or broken Microsoft Store source no longer stops the install.
- Tailscale is found in `C:\Program Files\Tailscale` even when the PowerShell window was opened before Tailscale was installed.
- Clearer message when the work folder does not exist; the guide now says to create it first.
- The guide explains where the downloaded ZIP unzips to and which folder to open.

## 1.1.0 (2026-11-15)

- `-DryRun` for `connect-clients.ps1` and `register-hooks.ps1`: list what would change before changing it.
- GitHub Copilot support (`~/.copilot/copilot-instructions.md`, `~/.copilot/skills`); a note for Cursor, which has no user-level instructions file.

## 1.0.0 (2026-11-15)

- First public release: one shared brain (instructions, rules, skills, handoffs, hooks, automatic memory and a notes vault) for AI assistants on all your Windows machines, synced with Syncthing over Tailscale only.
- MIT license.
