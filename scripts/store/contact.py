#!/usr/bin/env python3
# 1.1 store — the contact sheet: thumbs/ (360 px JPEGs, committed) + contact-sheet.html grouped by shot, each thumb
# labelled with its file and linked to the full-size still / clip (those stay on this Mac). Usage: contact.py <root>
import html, os, re, subprocess, sys
R = sys.argv[1]; T = os.path.join(R, "thumbs"); os.makedirs(T, exist_ok=True)
SHOTS = [("01", "Map in a Pro look on a custom background"), ("02", "The Librarian answering"), ("03", "Share sheet over Safari"),
         ("04", "Entry with text, a table and an image"), ("05", "Every look, for the grid"), ("06", "Private entries and Face ID"),
         ("07", "Export and Save to folder"), ("08", "Bring your own model")]
def thumb(src, name):
    out = os.path.join(T, name + ".jpg")
    if not os.path.exists(out):
        subprocess.run(["magick", src, "-resize", "360x", "-quality", "72", out], check=True)
    return "thumbs/" + name + ".jpg"
parts = ["<!doctype html><meta charset=utf-8><title>1.1 store contact sheet</title><style>body{font:13px -apple-system,system-ui;"
         "background:#F4F2ED;color:#232A2E;margin:24px}h2{margin:28px 0 8px}h3{margin:14px 0 6px;color:#666;font-weight:500}"
         ".g{display:flex;flex-wrap:wrap;gap:12px}.c{width:180px}.c img{width:180px;border-radius:8px;display:block}"
         ".c div{word-break:break-all;margin-top:4px;color:#555}</style><h1>1.1 store: raw stills and clips</h1>"
         "<p>Thumbnails link to the full-size files in <code>stills/</code> and <code>clips/</code> (on this Mac). See README.md and manifest.md.</p>"]
for n, title in SHOTS:
    parts.append(f"<h2>{n} · {html.escape(title)}</h2>")
    for dev in sorted(os.listdir(os.path.join(R, "stills"))):
        fs = sorted(f for f in os.listdir(os.path.join(R, "stills", dev)) if f.startswith(n + "-") and f.endswith(".png"))
        if not fs: continue
        parts.append(f"<h3>{dev}</h3><div class=g>")
        for f in fs:
            rel = f"stills/{dev}/{f}"; t = thumb(os.path.join(R, rel), dev + "__" + f[:-4])
            parts.append(f'<a class=c href="{rel}"><img loading=lazy src="{t}"><div>{html.escape(f)}</div></a>')
        parts.append("</div>")
parts.append("<h2>Clips (iPhone 17 Pro; the frame from the middle of each)</h2><div class=g>")
for f in sorted(os.listdir(os.path.join(R, "clips"))):
    if not f.endswith(".mov"): continue
    p = os.path.join(R, "clips", f)
    d = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p], capture_output=True, text=True).stdout)
    png = os.path.join(T, "_mid.png")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(d / 2), "-i", p, "-frames:v", "1", png], check=True)
    t = thumb(png, "clip__" + f[:-4]); os.remove(png)
    parts.append(f'<a class=c href="clips/{f}"><img loading=lazy src="{t}"><div>{html.escape(f)} · {d:.0f} s</div></a>')
parts.append("</div>")
open(os.path.join(R, "contact-sheet.html"), "w").write("\n".join(parts))
print(len(os.listdir(T)), "thumbs")
