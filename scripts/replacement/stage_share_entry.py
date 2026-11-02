#!/usr/bin/env python3
"""Stage one user entry in the App Group share inbox, shaped like a Sample entry (real Node JSON), new id. Prints the id.
Usage: stage_share_entry.py <library-root> <inbox-dir>"""
import json, os, sys, uuid, glob, datetime
lib, inbox = sys.argv[1], sys.argv[2]
src = sorted(glob.glob(os.path.join(lib, "nodes", "*", "node.json")))[0]
node = json.load(open(src))
nid = str(uuid.uuid4()).upper()
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
text = {"id": str(uuid.uuid4()).upper(), "type": "text", "content": "UPGRADEPROBE entry made on the 1.0 build.",
        "created_at": now}
node.update({"id": nid, "title": "Upgrade probe", "summary": "", "tags": [], "items": [text],
             "created_at": now, "updated_at": now})
for k in ("cover_image_relative_path",): node.pop(k, None)
d = os.path.join(inbox, nid); os.makedirs(d, exist_ok=True)
json.dump(node, open(os.path.join(d, "node.json"), "w"))
print(nid)
