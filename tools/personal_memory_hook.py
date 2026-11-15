"""SessionStart hook: adds this machine's personal (not synced) memory index to each session.

Shared memory is loaded by the assistant itself. Personal notes that should stay on this machine
live in ~/.claude/personal-memory/ (the config root does not sync) and are added here.
"""
import json
import sys
from pathlib import Path

try:
    sys.stdin.read()
except Exception:
    pass
folder = Path(__file__).resolve().parent / "personal-memory"
index = folder / "MEMORY.md"
if not index.is_file():
    sys.exit(0)
body = index.read_text(encoding="utf-8")
text = (
    "# Personal memory of this machine (not synced)\n"
    f"Detail files are in {folder.as_posix()}/<file>. Personal notes that must not reach other machines "
    "go there, with one line added to this index; never into the shared memory folder.\n\n" + body
)
# ASCII-escaped JSON: hook output on Windows may use a legacy code page.
sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                                    "additionalContext": text}}, ensure_ascii=True))
sys.stdout.flush()
