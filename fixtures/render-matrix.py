#!/usr/bin/env python3
"""Render the hop summaries (logs/*/hop-*.summary.json) as a markdown matrix."""
import glob
import json
import os
import sys

rows = []
for path in sorted(glob.glob("logs/*/hop-*.summary.json")):
    with open(path) as f:
        d = json.load(f)
    d["_file"] = os.path.relpath(path)
    rows.append(d)

if not rows:
    sys.exit("no summaries found under logs/*/")

QUESTIONS = [
    ("boot", "server boots"),
    ("workspace_list", "workspace registry"),
    ("session_list", "session listed"),
    ("session_history", "session log readable"),
    ("settings", "user settings honored"),
]
mark = {"pass": "✅", "fail": "❌"}

print("| hop | platform | " + " | ".join(label for _, label in QUESTIONS) + " |")
print("|---|---|" + "---|" * len(QUESTIONS))
for r in rows:
    cells = [mark.get(r.get(key), "❓") for key, _ in QUESTIONS]
    print(f"| `{r['hop']}` | {r['platform']} | " + " | ".join(cells) + " |")
