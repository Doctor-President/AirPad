#!/usr/bin/env python3
# 1.1 store stills — synthetic entries added to the Sample scratch (-UITestLibrary -UITestSampleLibrary) and registered in
# its sample manifest, so they belong to the Sample Library like the bundled ones:
#   store-pourover  text + an inline image + a table, with a cover photo
#   store-private   a private entry (for "Show private")
# Photos: Wikimedia Commons "Manual drip (pour-over) coffee.jpg" (inline) and "Drip brewing (Unsplash).jpg" (cover), both CC0.
# Usage: seed_entry.py <scratch root> <inline jpg> <cover jpg>
import json, os, shutil, sys
root, inline_jpg, cover_jpg = sys.argv[1:4]
t = "2026-10-30T08:15:00Z"

def write(nid, node, files=()):
    d = os.path.join(root, "nodes", nid); os.makedirs(os.path.join(d, "items"), exist_ok=True)
    for src, name in files: shutil.copy(src, os.path.join(d, "items", name))
    json.dump(node, open(os.path.join(d, "node.json"), "w"), ensure_ascii=False, indent=1)

def media(iid):
    return {"id": iid, "type": "image_video", "created_at": t, "file": f"items/{iid}.jpg",
            "media_items": [{"id": iid, "media_type": "image", "file": f"items/{iid}.jpg", "aspect_ratio": 1.5, "captured_at": t}]}

base = {"connections": [], "created_at": t, "updated_at": t, "entry_schema_version": 4, "is_meta": False,
        "needs_ai_processing": False, "threads": []}

img, cov = "5A0C0FFE-0000-4000-8000-000000000001", "5A0C0FFE-0000-4000-8000-000000000002"
md = ("Same Guji, three mornings. The grind mattered most.\n\n"
      f"![](airpad-image:{img})\n\n"
      "| Morning | Grind | Time | Cup |\n|---|---|---|---|\n"
      "| Thu | 22 | 3:10 | thin |\n| Fri | 18 | 3:40 | bitter |\n| Sat | 20 | 3:25 | the one |\n\n"
      "Next bag: start at 20 and leave it there.")
write("store-pourover", {**base, "id": "store-pourover", "collection_ids": ["coffee"],
      "title": "Pour-over, dialled in", "summary": "Three mornings of the same Guji: grind, time, cup.",
      "tags": ["coffee"], "tag_sources": {"coffee": {"source": "user"}},
      "cover_image_relative_path": f"items/{cov}.jpg",
      "items": [{"id": "store-pourover-note", "type": "text", "created_at": t, "updated_at": t, "content": md, "is_expanded": True},
                media(img), media(cov)]},
      [(inline_jpg, img + ".jpg"), (cover_jpg, cov + ".jpg")])

write("store-private", {**base, "id": "store-private", "collection_ids": [], "is_private": True,
      "title": "Birthday ideas for Sam", "summary": "Three ideas, one budget.",
      "tags": [], "tag_sources": {},
      "items": [{"id": "store-private-note", "type": "text", "created_at": t, "updated_at": t, "is_expanded": True,
                 "content": "Keep this one quiet.\n\n- the good notebook\n- a pour-over kettle\n- tickets for the Friday show"}]})

m = os.path.join(root, "sample_library.json"); man = json.load(open(m))
for nid in ("store-pourover", "store-private"):
    if nid not in man["nodeIDs"]: man["nodeIDs"].append(nid)
json.dump(man, open(m, "w"))
print("seeded; manifest nodes:", len(man["nodeIDs"]))
