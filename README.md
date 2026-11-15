# AI Brain kit: one shared brain for your AI assistants on all your Windows machines

The kit gives your AI coding assistants (the one that keeps its settings in `~/.claude`, plus Codex, Gemini/Antigravity, OpenCode, GitHub Copilot and Cursor if installed) one shared "brain" across your machines:

- main instructions (`~/.claude/CLAUDE.md`), rules, skills, agents, commands, handoffs and hooks;
- the automatic memory of your main work folder;
- a notes vault (`~/AI Brain`) you can open in Obsidian or any editor.

Everything syncs with **Syncthing, only over your own Tailscale network**: no cloud storage, no public relays. Sign-ins, `settings.json` and conversation history never sync.

> Windows 10/11. macOS support is **experimental** (see [macOS](#macos-experimental)): it has passed tests against Windows machines but not yet on a real Mac.

## What you need on every machine

1. **Tailscale**, signed in to **your own** account (all your machines in the same tailnet). Do not join someone else's tailnet.
2. **winget** (App Installer from the Microsoft Store; present on current Windows).
3. Optional: **Python 3** for hooks (the kit can install it).

## 1. Download

Download the kit: the ZIP attached to the latest **Release** on GitHub, or **Code > Download ZIP**. Unzip it and open the folder that contains `Setup.cmd`, `tools\` and `templates\`. Windows often adds one more folder level: with **Code > Download ZIP** the right folder is usually `Downloads\ai-brain-kit-main\ai-brain-kit-main`. What changed in each version is in `CHANGELOG.md`.

## 2. The easy way: double-click `Setup.cmd`

If Windows asks whether to run a file downloaded from the internet, choose **Run**. Setup unblocks the kit's files, checks Tailscale (and offers to install it), lets you pick your work folder in a normal folder window, and does the rest.

**First machine:** choose **1 Start a new brain**. Then edit `~/.claude/CLAUDE.md` with your own rules.

**Each additional machine** (three short steps, no IDs to copy):
1. On a machine that already has the brain: Setup > **Invite another machine**. It shows an **invite code** (`AIB1-...`) and the same code as a QR. Send the text to the new machine any way you like (a note to yourself, a chat with yourself, or scan the QR with your phone).
2. On the new machine: Setup > **2 Join**, paste the code, pick the work folder.
3. Back on the first machine: Setup > **Accept a new machine**. It shows the new machine's name and address; say yes only if you recognise it.

The new machine's own `CLAUDE.md`, rules, skills, handoffs, hooks and memory are moved to a backup folder first, so the first sync does not create conflict copies. Running Setup again later gives you **Check**, **Reconnect AI tools** and **Hooks**.

If your organisation controls which scripts may run on the PC, Setup stops and says so: ask your IT team. The kit never tries to get around such a policy.

## 3. The same with commands

Open PowerShell in the kit folder, unblock the files once (`Get-ChildItem -Recurse | Unblock-File`), and run each script as `powershell -NoProfile -ExecutionPolicy Bypass -File tools\<script>.ps1 ...` (the flag applies to that one run only; it changes no system setting).

| Step | Command |
|---|---|
| First machine (the work folder must exist: `mkdir "D:\Work"`) | `tools\install.ps1 -WorkFolder "D:\Work"` |
| Invite code, on a machine with the brain | `tools\invite.ps1` |
| New machine joins | `tools\install.ps1 -WorkFolder "D:\Work" -Invite AIB1-...` |
| Accept it, on the inviting machine | `tools\accept.ps1` |

After the first install the tools also live in `~\AI Brain\_tools`. The installer waits up to 30 minutes for the first sync, then links the vault and AI tools; if it times out, run the same command again. Without an invite code you can still pair by hand: `install.ps1 ... -PeerId <Device ID> -PeerIp <100.x.y.z>` on the new machine and `add-peer.ps1 -PeerId ... -PeerIp ... -PeerName ...` on the other.

To keep syncing while one machine is off, invite and accept so that every machine is paired with every other one.

## macOS (experimental)

Needs Python 3 (`python3 --version` in Terminal; macOS offers to install it if missing) and Tailscale signed in to the same account as your other machines.

1. Unzip the kit and open Terminal in its folder (`cd ~/Downloads/<kit folder>`).
2. Create your work folder if it is new: `mkdir -p ~/Work`.
3. First machine of your brain: `python3 tools/mac/brain.py install --work-folder ~/Work`
   Joining an existing brain: get an invite code from a machine that has it (Setup > Invite on Windows, or `python3 tools/mac/brain.py invite` on a Mac), then:
   `python3 tools/mac/brain.py install --work-folder ~/Work --invite AIB1-...`
   and accept it on the inviting machine.
4. Check: `python3 tools/mac/brain.py check`. Other commands: `invite`, `accept`, `connect-clients`, `register-hooks`.

The Mac installer downloads the official Syncthing release from Syncthing's GitHub page, verifies its SHA-256 checksum, keeps it in `~/.ai-brain/bin`, and starts it at login with a LaunchAgent.

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
