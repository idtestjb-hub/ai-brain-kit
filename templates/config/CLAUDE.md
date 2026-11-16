# How to work with me

Replace this template with your own working rules. Keep it short and concrete. Suggested sections:

## 1. Before you start
- Confirm the scope: which files, which period, how many rows or items.
- State the rules or assumptions you will apply, then wait for my OK when there is more than one sensible way.

## 2. Output
- Edit the file I name directly. Ask once when the output format is unclear.
- No secrets (passwords, keys, tokens) in scripts, files or chat.

## 3. Environment
- Shell, operating system, tools I use, folders to avoid.

## 4. Handoffs
- When a session gets long or the work moves to a new phase, write a handoff in `~/.claude/handoffs/` (format in `AGENTS.md` in the vault).
- Every handoff names where it came from and who should continue:
  - `Handed off from: <machine> · <assistant> · <model>`
  - `Suggested next: <assistant> · <model> · <effort> (<short reason>)`
- End the reply with one line to paste as the first message of the new session:
  `Continue [Project] (from <machine> · <assistant> <model> → use <assistant> · model <model> · effort <level>): read ~/.claude/handoffs/<file>.md and follow it`

## 5. Shared brain
- This machine shares this file, the rules, skills, handoffs, hooks and memory with my other machines. See `rules/shared-context.md`.
