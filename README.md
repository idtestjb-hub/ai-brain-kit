# AI Brain kit: one shared brain for your AI assistants on all your Windows machines

The kit gives your AI coding assistants (the one that keeps its settings in `~/.claude`, plus Codex, Gemini/Antigravity, OpenCode, GitHub Copilot and Cursor if installed) one shared "brain" across your machines:

- main instructions (`~/.claude/CLAUDE.md`), rules, skills, agents, commands, handoffs and hooks;
- the automatic memory of your main work folder;
- a notes vault (`~/AI Brain`) you can open in Obsidian or any editor.

Everything syncs with **Syncthing, only over your own Tailscale network**: no cloud storage, no public relays. Sign-ins, `settings.json` and conversation history never sync.

> Version 1 supports Windows 10/11 only.

## What you need on every machine

1. **Tailscale**, signed in to **your own** account (all your machines in the same tailnet). Do not join someone else's tailnet.
2. **winget** (App Installer from the Microsoft Store; present on current Windows).
3. Optional: **Python 3** for hooks (the kit can install it).

## 1. Unpack

1. Download the kit: the ZIP attached to the latest **Release** on GitHub, or **Code > Download ZIP**. Unzip it and use the folder that contains `tools\` and `templates\`. Windows often adds one more folder level: with **Code > Download ZIP** the right folder is usually `Downloads\ai-brain-kit-main\ai-brain-kit-main`. What changed in each version is in `CHANGELOG.md`.
2. Open PowerShell in that folder (for example `cd "$env:USERPROFILE\Downloads\ai-brain-kit-main\ai-brain-kit-main"`, then `dir` should list `tools` and `templates`) and unblock the files once:
   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```
3. Run every script below with:
   `powershell -NoProfile -ExecutionPolicy Bypass -File tools\<script>.ps1 ...`
   (the flag applies to that one run only; it changes no system setting).

## 2. First machine

Pick your main work folder (the folder you usually open the assistant in). It must already exist; on a brand-new machine create it first, for example `mkdir "D:\Work"`. Then:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\install.ps1 -WorkFolder "D:\Work"
```
This installs Syncthing for your user, creates the vault from empty templates (existing files are kept), limits Syncthing to Tailscale, shares three folders (`ai-claude`, `ai-memory`, `ai-brain`), adds a sign-in task, and links the vault with installed AI tools. It prints this machine's **Device ID** and **Tailscale IP**: keep them for step 3.

Then edit `~/.claude/CLAUDE.md` with your own rules.

## 3. Each additional machine

On the new machine (its vault must be empty):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\install.ps1 -WorkFolder "D:\Work" -PeerId <ID of first machine> -PeerIp <IP of first machine> -PeerName main
```
Existing `CLAUDE.md`, rules, skills, handoffs, hooks and memory on the new machine are moved to a backup folder first, so the first sync does not create conflict copies.

On the first machine, using the new machine's ID and IP printed above:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\AI Brain\_tools\add-peer.ps1" -PeerId <new ID> -PeerIp <new IP> -PeerName laptop
```
The installer waits up to 30 minutes for the first sync, then links the vault and AI tools. If it times out, run the same install command again.

To keep syncing while one machine is off, pair every machine with every other one using `add-peer.ps1` on both sides.

## 4. Hooks (optional)

Put shared hook scripts (`<name>.py`) in `~/.claude/hooks/` and list them in `~/.claude/hooks/hooks.json`, for example:
```json
{ "hooks": [ { "name": "py_syntax_check", "event": "PostToolUse", "matcher": "Write|Edit|MultiEdit", "timeout": 15 } ] }
```
The hooks and the list sync; each machine's `settings.json` does not. So on **every** machine run:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\AI Brain\_tools\register-hooks.ps1" -InstallPython
```
Run it again whenever `hooks.json` changes. Add `-PersonalMemory` on machines where you also want notes that stay on that machine only (`~/.claude/personal-memory/`).

## 5. Move the data to another drive (optional)

Close all AI apps (also from the tray), then:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\AI Brain\_tools\move-data.ps1" -DataRoot "E:\AI-Brain" -Check
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\AI Brain\_tools\move-data.ps1" -DataRoot "E:\AI-Brain"
```
The real folders move to the new drive; junctions with the same names stay in your profile, so nothing else changes. The new folder is readable only by you, SYSTEM and Administrators. Moving does **not** encrypt anything: use BitLocker if the drive could be removed or stolen. Delete the backup folder the script names once all works (it holds your sign-in files). Never delete the junctions in your profile.

## 6. Check

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\AI Brain\_tools\check.ps1"
```

## What syncs, what does not

| Syncs (all machines) | Stays on each machine |
|---|---|
| `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/`, `handoffs/`, `hooks/` | sign-ins, `settings.json`, plugins, connectors |
| memory of the main work folder | conversation history, other folders' memory |
| the vault | `~/.claude/personal-memory/`, hook temp files |

After adding a skill or editing `AGENTS.md`, run `_tools/connect-clients.ps1` on each machine so the other AI tools see it. Add `-DryRun` first to list what it would change (`register-hooks.ps1` takes `-DryRun` too).

| Tool | Gets the shared instructions in | Gets the skills in |
|---|---|---|
| Codex | `~/.codex/AGENTS.md` | `~/.agents/skills` |
| Gemini / Antigravity | `~/.gemini/GEMINI.md` | `~/.gemini/config/skills`, `~/.gemini/antigravity/skills` |
| OpenCode | `~/.config/opencode/AGENTS.md` | — |
| GitHub Copilot (VS Code and CLI) | `~/.copilot/copilot-instructions.md` | `~/.copilot/skills` |
| Cursor | no user-level file: paste `AGENTS.md` once into Cursor Settings > Rules | reads `~/.claude/skills` by itself |

A tool's existing file that the kit did not write is backed up before the first overwrite.

## Safety

- Keep secrets (passwords, keys, tokens) and data files out of the brain.
- Do not edit the same file on two machines while one is offline; merge any `*.sync-conflict-*` file by hand.
- Keep Obsidian Sync off: the vault contains junctions.

## Uninstall

1. Task Scheduler: delete the task "AI Brain - Syncthing"; quit Syncthing.
2. Delete `~/.ai-brain` (Syncthing state). Your vault and `~/.claude` stay as normal folders.
3. Optionally remove the hook entries the kit added to `~/.claude/settings.json` (a backup sits next to it).
