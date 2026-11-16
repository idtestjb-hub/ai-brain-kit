# Changelog

## 1.3.2 (2026-11-17)

- When a step of the two-machine test fails, the test now prints what the kit command said, so a failure on GitHub can be traced without rerunning it on your PC. A missing folder link is reported as a failed check instead of stopping the whole test.
- The automatic tests run once per commit; creating a release no longer starts a second, identical run.

## 1.3.1 (2026-11-17)

- **Automatic tests on GitHub:** every push and pull request now runs the kit's tests: every script is checked in Windows PowerShell 5.1 and PowerShell 7, the macOS tool runs its self-test, and two fake machines install, pair, sync and turn hooks and plan-usage warnings on and off. The result shows as a check mark next to each commit.
- The kit now includes its tests in `tests/`, so you can run the two-machine test on your own PC (see "Tests" in the guide). Nothing changes for an existing install.

## 1.3.0 (2026-11-16)

- **Plan-usage warnings (optional, off by default):** a small mod warns when the plan's 5-hour or weekly usage limit reaches 80% and 90%, and at 95% asks the assistant to finish the current step and write a handoff. The three levels can be changed. Turn it on or off per machine in Setup, with `usage-guard.ps1 -On/-Off`, `install.ps1 -UsageGuard`, or `brain.py usage-guard --on/--off` on a Mac. It only adds one line to that machine's `settings.json` (backed up first) and does not sync. `check` shows whether it is on.
- **Handoff format:** the templates for `AGENTS.md` and `CLAUDE.md` now ask every handoff to say where it came from (`Handed off from: <machine> · <assistant> · <model>`) and who should continue (`Suggested next: <assistant> · <model> · <effort> (<reason>)`), and to end with one line to paste into the new session. An assistant that cannot write to `~/.claude/handoffs/` writes the handoff in its working folder instead. Existing vaults keep their own `AGENTS.md`; copy the new section in by hand if you want it.
- The build's leak scan also checks for the builder's own user and machine names.

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
