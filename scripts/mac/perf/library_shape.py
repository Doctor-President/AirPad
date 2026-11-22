#!/usr/bin/env python3
"""Sweep 2b 0.2 — the SHAPE of a library, numbers only.

  library_shape.py <library root> [--json out.json]

Reads a library folder read-only (node.json files, media file headers via `sips`, chats.json, collections.json) and
prints counts, sizes and distributions. It never prints a title, a word of any note, a file name, a tag, a
collection name or a path: only numbers and the app's own type names. Used on T's library to shape the realistic
test library (`-UITestSeedRealisticLibrary`), whose content is synthetic. Evicted iCloud files (`.name.icloud`
stubs) are counted, never downloaded.
"""
import json, os, re, subprocess, sys, statistics as st

SF_DATALESS = 0x40000000


def dataless(fp):
    try:
        return bool(os.lstat(fp).st_flags & SF_DATALESS)
    except OSError:
        return True


IMG = re.compile(r"\.(jpe?g|png|heic|heif|gif|webp|tiff?)$", re.I)
VID = re.compile(r"\.(mov|mp4|m4v)$", re.I)


def pct(xs, ps=(10, 50, 90, 99)):
    if not xs:
        return {"n": 0}
    xs = sorted(xs)
    out = {"n": len(xs), "min": xs[0], "max": xs[-1], "mean": round(st.mean(xs), 1)}
    for p in ps:
        out[f"p{p}"] = xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]
    return out


def dims(paths):
    """pixel width/height via sips, in batches; returns list of (w, h)."""
    out = []
    for i in range(0, len(paths), 200):
        r = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", *paths[i:i + 200]],
                           capture_output=True, text=True)
        w = None
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith("pixelWidth:"):
                w = int(line.split()[-1])
            elif line.startswith("pixelHeight:") and w is not None:
                out.append((w, int(line.split()[-1])))
                w = None
    return out


def md_shape(text):
    lines = text.splitlines()
    tables = 0
    in_table = False
    for l in lines:
        is_row = l.strip().startswith("|") and l.strip().count("|") >= 2
        if is_row and not in_table:
            tables += 1
        in_table = is_row
    return {
        "words": len(text.split()),
        "chars": len(text),
        "lines": len(lines),
        "tables": tables,
        "table_rows": sum(1 for l in lines if l.strip().startswith("|") and l.strip().count("|") >= 2),
        "headings": sum(1 for l in lines if re.match(r"^#{1,6} ", l)),
        "list_lines": sum(1 for l in lines if re.match(r"^\s*([-*+]|\d+\.) ", l)),
        "checkboxes": sum(1 for l in lines if re.match(r"^\s*[-*+] \\?\[[ xX]\\?\]", l)),
        "inline_images": len(re.findall(r"!\[[^\]]*\]\(", text)),
        "links_md": len(re.findall(r"\]\(https?://", text)),
    }


def main():
    root = sys.argv[1]
    out_json = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    ndir = os.path.join(root, "nodes")
    entries = [d for d in os.listdir(ndir) if os.path.isdir(os.path.join(ndir, d))]
    S = {"entries_folders": len(entries)}
    unreadable = 0
    per = []
    img_paths, img_bytes, vid_bytes, doc_bytes, aud_bytes, other_bytes = [], [], [], [], [], []
    stubs = 0
    dataless_files = dataless_bytes = 0
    folder_bytes = []
    for d in entries:
        p = os.path.join(ndir, d)
        fb = 0
        for r, _, fs in os.walk(p):
            for f in fs:
                fp = os.path.join(r, f)
                if f.endswith(".icloud"):
                    stubs += 1
                    continue
                try:
                    b = os.path.getsize(fp)
                except OSError:
                    continue
                fb += b
                if dataless(fp):
                    dataless_files += 1; dataless_bytes += b
                    if f == "node.json":
                        continue
                    if IMG.search(f):
                        img_bytes.append(b)
                    continue
                if f == "node.json":
                    continue
                if IMG.search(f):
                    img_paths.append(fp); img_bytes.append(b)
                elif VID.search(f):
                    vid_bytes.append(b)
                elif f.lower().endswith(".pdf") or f.lower().endswith((".docx", ".pages", ".key", ".numbers", ".xlsx", ".txt", ".md", ".rtf")):
                    doc_bytes.append(b)
                elif f.lower().endswith((".m4a", ".mp3", ".wav", ".caf", ".aac")):
                    aud_bytes.append(b)
                else:
                    other_bytes.append(b)
        folder_bytes.append(fb)
        nj = os.path.join(p, "node.json")
        if not os.path.exists(nj) or dataless(nj):
            unreadable += 1
            continue
        try:
            n = json.load(open(nj))
        except Exception:
            unreadable += 1
            continue
        items = n.get("items", [])
        text = "\n\n".join(i.get("content") or "" for i in items if i.get("type") == "text")
        e = {
            "journal": bool(n.get("is_journal_entry")) and bool(n.get("journal_date")),
            "is_journal_flag": bool(n.get("is_journal_entry")),
            "title_len": len(n.get("title") or ""),
            "title_empty": not (n.get("title") or "").strip(),
            "summary_words": len((n.get("summary") or "").split()),
            "tags": len(n.get("tags") or []),
            "collections": len(n.get("collection_ids") or []),
            "cover": bool(n.get("cover_image_relative_path")),
            "hero_crop": bool(n.get("hero_crop")),
            "private": bool(n.get("is_private")),
            "items": len(items),
            "types": {},
            "media": sum(len(i.get("media_items") or []) for i in items),
            "docs": sum(len(i.get("document_items") or []) or (1 if i.get("type") == "document" else 0) for i in items),
            "links": sum(len(i.get("link_items") or []) or (1 if i.get("type") == "link" else 0) for i in items),
            "audio": sum(1 for i in items if i.get("type") == "audio"),
            "audio_secs": [i.get("duration_seconds") or 0 for i in items if i.get("type") == "audio"],
            "text_items": sum(1 for i in items if i.get("type") == "text"),
            "fields": sum(1 for i in items if i.get("type") == "field"),
            "created": (n.get("created_at") or "")[:7],
            "updated": (n.get("updated_at") or "")[:7],
            "md": md_shape(text),
        }
        for i in items:
            e["types"][i.get("type")] = e["types"].get(i.get("type"), 0) + 1
        per.append(e)
    S["entries_readable"] = len(per)
    S["entries_unreadable"] = unreadable
    S["evicted_stubs"] = stubs
    S["dataless_files"] = dataless_files
    S["dataless_bytes"] = dataless_bytes
    S["library_bytes_nodes"] = sum(folder_bytes)
    S["entry_folder_bytes"] = pct(folder_bytes)
    S["journal_entries"] = sum(e["journal"] for e in per)
    S["journal_flag_entries"] = sum(e["is_journal_flag"] for e in per)
    S["untitled"] = sum(e["title_empty"] for e in per)
    S["title_chars"] = pct([e["title_len"] for e in per])
    S["with_cover"] = sum(e["cover"] for e in per)
    S["with_hero_crop"] = sum(e["hero_crop"] for e in per)
    S["private"] = sum(e["private"] for e in per)
    tt = {}
    for e in per:
        for k, v in e["types"].items():
            tt[k] = tt.get(k, 0) + v
    S["item_types_total"] = tt
    S["entries_with_type"] = {k: sum(1 for e in per if k in e["types"]) for k in tt}
    S["items_per_entry"] = pct([e["items"] for e in per])
    for k in ("media", "docs", "links", "audio", "fields", "text_items", "tags", "collections", "summary_words"):
        S[f"{k}_per_entry"] = pct([e[k] for e in per])
        S[f"{k}_per_entry_nonzero"] = pct([e[k] for e in per if e[k]])
    S["audio_seconds"] = pct([s for e in per for s in e["audio_secs"]])
    for k in ("words", "chars", "lines", "tables", "table_rows", "headings", "list_lines", "checkboxes",
              "inline_images", "links_md"):
        S[f"note_{k}"] = pct([e["md"][k] for e in per])
        S[f"entries_with_{k}"] = sum(1 for e in per if e["md"][k])
    # word buckets
    b = {"0": 0, "1-50": 0, "51-200": 0, "201-500": 0, "501-1500": 0, "1501-5000": 0, "5001+": 0}
    for e in per:
        w = e["md"]["words"]
        k = "0" if w == 0 else "1-50" if w <= 50 else "51-200" if w <= 200 else "201-500" if w <= 500 else \
            "501-1500" if w <= 1500 else "1501-5000" if w <= 5000 else "5001+"
        b[k] += 1
    S["note_word_buckets"] = b
    months = {}
    for e in per:
        months[e["created"]] = months.get(e["created"], 0) + 1
    S["created_by_month"] = dict(sorted(months.items()))
    S["images"] = {"count": len(img_bytes), "count_local": len(img_paths), "bytes": pct(img_bytes), "total_bytes": sum(img_bytes)}
    ext = {}
    for pth in img_paths:
        x = pth.rsplit(".", 1)[-1].lower()
        ext[x] = ext.get(x, 0) + 1
    S["images"]["formats"] = ext
    dd = dims(img_paths)
    S["images"]["long_edge_px"] = pct([max(w, h) for w, h in dd])
    S["images"]["megapixels_x10"] = pct([round(w * h / 1e5) for w, h in dd])
    S["images"]["portrait"] = sum(1 for w, h in dd if h > w)
    S["videos"] = {"count": len(vid_bytes), "bytes": pct(vid_bytes), "total_bytes": sum(vid_bytes)}
    S["documents"] = {"count": len(doc_bytes), "bytes": pct(doc_bytes), "total_bytes": sum(doc_bytes)}
    S["audio_files"] = {"count": len(aud_bytes), "bytes": pct(aud_bytes), "total_bytes": sum(aud_bytes)}
    S["other_files"] = {"count": len(other_bytes), "total_bytes": sum(other_bytes)}
    # collections, chats
    try:
        cols = json.load(open(os.path.join(root, "collections.json")))
        cols = cols if isinstance(cols, list) else cols.get("collections", [])
        S["collections"] = len(cols)
    except Exception:
        S["collections"] = None
    counts = {}
    for d in entries:
        if dataless(os.path.join(ndir, d, "node.json")):
            continue
        try:
            n = json.load(open(os.path.join(ndir, d, "node.json")))
        except Exception:
            continue
        for c in n.get("collection_ids") or []:
            counts[c] = counts.get(c, 0) + 1
    S["entries_per_collection"] = pct(list(counts.values()))
    try:
        chats = json.load(open(os.path.join(root, "chats.json")))
        chats = chats if isinstance(chats, list) else chats.get("chats", [])
        S["chats"] = len(chats)
        S["messages_per_chat"] = pct([len(c.get("messages", [])) for c in chats])
        S["chars_per_message"] = pct([len(m.get("text") or "") for c in chats for m in c.get("messages", [])])
    except Exception:
        S["chats"] = None
    try:
        tags = json.load(open(os.path.join(root, "tags.json")))
        S["tags_file_entries"] = len(tags) if isinstance(tags, (list, dict)) else None
    except Exception:
        S["tags_file_entries"] = None
    S["distinct_tags_on_entries"] = len({t for d in entries for t in (lambda n: n.get("tags") or [])(
        (lambda p: json.load(open(p)) if os.path.exists(p) and not dataless(p) else {})(os.path.join(ndir, d, "node.json")))})
    txt = json.dumps(S, indent=1)
    print(txt)
    if out_json:
        open(out_json, "w").write(txt + "\n")


if __name__ == "__main__":
    main()
