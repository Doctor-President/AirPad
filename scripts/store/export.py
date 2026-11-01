#!/usr/bin/env python3
# 1.1 store — copy a result bundle's named attachments (stills) into <dst>, by the name the test gave them.
# Usage: export.py <xcresult> <dst>
import json, os, shutil, subprocess, sys, tempfile
rb, dst = sys.argv[1], sys.argv[2]; tmp = tempfile.mkdtemp()
subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", rb, "--output-path", tmp], capture_output=True)
m = json.load(open(os.path.join(tmp, "manifest.json"))); n = 0
for t in m:
    for a in t.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        if "_0_" not in name: continue            # XCTest's own (UI snapshots, recordings, descriptions)
        stem = name.split("_0_")[0]; ext = os.path.splitext(a["exportedFileName"])[1]
        shutil.copy(os.path.join(tmp, a["exportedFileName"]), os.path.join(dst, stem + ext)); n += 1
print(n, "attachments →", dst)
