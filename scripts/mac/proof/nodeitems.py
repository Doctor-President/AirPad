# nodeitems.py <node id> — the entry's items as stored (isolated copy's container): type · name · gallery/doc members
import json, sys, os
p = os.path.expanduser(f"~/Library/Containers/com.doctorpresident.airpad.macA/Data/Documents/AirPad/nodes/{sys.argv[1]}/node.json")
n = json.load(open(p))
for i, it in enumerate(n.get("items", [])):
    t = it.get("type"); nm = it.get("display_name") or ""
    extra = ""
    if t == "document": extra = " docs=[" + ", ".join(d.get("file_name", "?") for d in it.get("document_items", [])) + "]"
    if t == "image_video":
        m = it.get("media_items", [])
        extra = " media=%d last=[%s]" % (len(m), ", ".join(str(g.get("original_name") or g.get("file", "?")) for g in m[-2:]))
    print(f"{i} {t} {nm!r}{extra} id={it.get('id','')[:8]}")
