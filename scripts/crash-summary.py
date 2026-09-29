#!/usr/bin/env python3
"""The newest simulator crash report of an app, as one line for a CI
annotation: exception, Swift runtime message and the crashed thread's top
frames. Usage: crash-summary.py <process name> [since-epoch-seconds]"""
import glob
import json
import os
import sys

name = sys.argv[1] if len(sys.argv) > 1 else "GlassifAI"
since = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
paths = [
    path
    for path in glob.glob(os.path.expanduser(f"~/Library/Logs/DiagnosticReports/{name}*.ips"))
    if os.path.getmtime(path) >= since
]
if not paths:
    print("no crash report")
    sys.exit(0)
path = max(paths, key=os.path.getmtime)
text = open(path, encoding="utf-8", errors="replace").read()
# An .ips file is a one-line JSON header followed by the JSON report.
_, _, body = text.partition("\n")
try:
    data = json.loads(body)
except ValueError:
    print(" ".join(text[:600].split()))
    sys.exit(0)

exception = data.get("exception", {})
parts = [f"{exception.get('type', '?')} {exception.get('signal', '')}".strip()]
asi = data.get("asi")
if asi:
    parts.append("message: " + json.dumps(asi, ensure_ascii=True)[:400])
termination = data.get("termination", {})
if termination.get("indicator"):
    parts.append(f"termination: {termination.get('indicator')}")
images = data.get("usedImages", [])
threads = data.get("threads", [])
crashed = next((thread for thread in threads if thread.get("triggered")), threads[0] if threads else {})
frames = []
for frame in crashed.get("frames", [])[:16]:
    index = frame.get("imageIndex")
    image = images[index].get("name", "?") if isinstance(index, int) and index < len(images) else "?"
    symbol = frame.get("symbol") or hex(frame.get("imageOffset", 0))
    frames.append(f"{image}:{symbol}")
parts.append(" < ".join(frames))
print(" | ".join(parts))
