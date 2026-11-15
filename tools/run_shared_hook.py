"""Runs one shared hook from ~/.claude/hooks (the hooks folder syncs between machines).

This launcher lives in the config root, which does not sync, so each machine keeps its own copy.
If the hook has not arrived on this machine yet, it exits 0 so it never blocks a prompt.
Usage: python -B run_shared_hook.py <hook name without .py>
"""
import subprocess
import sys
from pathlib import Path

if len(sys.argv) < 2:
    sys.exit(0)
hook = Path(__file__).resolve().parent / "hooks" / f"{sys.argv[1]}.py"
if not hook.is_file():
    sys.exit(0)
data = sys.stdin.buffer.read()
proc = subprocess.run([sys.executable, "-B", str(hook)], input=data,
                      stdout=sys.stdout.buffer, stderr=sys.stderr.buffer)
sys.exit(proc.returncode)
