#!/usr/bin/env python3
# 1.1 store — manifest.md for design-refs/1.1-store/: every still and clip with its pixel size (and, for clips, duration,
# the frames actually recorded and the measured fps), plus what it shows. Usage: manifest.py <root>
import json, os, re, subprocess, sys
root = sys.argv[1]
SHOT = {"01": "Map in a Pro look on a custom background", "02": "The Librarian answering", "03": "Share sheet over Safari",
        "04": "Entry with text, a table and an image", "05": "The Map in each look (for the grid)",
        "06": "Private entries and Face ID", "07": "Export and Save to folder", "08": "Bring your own model", "x": "Extra"}
WHAT = [
  (r"01-map-(\w+)-(dark|light)-([\w-]+)", lambda m: f"Map, {m[1].title()} look, {m[2]}, custom background “{m[3]}”"),
  (r"01-map-(\w+)-(dark|light)-([\w-]+)-zoomed", None),
  (r"05-look-(\w+)-(dark|light)", lambda m: f"Map, {m[1].title()} look, {m[2]}, default background"),
  (r"02-librarian-empty", lambda m: "Librarian open, empty Ask field"),
  (r"02-librarian-typed", lambda m: "Question typed, keyboard up"),
  (r"02-librarian-t(\d+)", lambda m: f"Answer streaming, {int(m[1])+1} s after Send"),
  (r"02-librarian-done-sources-b", lambda m: "Finished answer scrolled to the numbered sources"),
  (r"02-librarian-done-sources", lambda m: "Finished answer with “Show sources” opened"),
  (r"02-librarian-done", lambda m: "Finished answer with superscript citations"),
  (r"03-safari-page", lambda m: "Safari on the neutral article page"),
  (r"03-system-share-sheet", lambda m: "The system share sheet with AirPad in it"),
  (r"03-airpad-share-sheet", lambda m: "AirPad’s share sheet over Safari (title, note, Save to)"),
  (r"03-airpad-share-existing", lambda m: "AirPad’s share sheet, “Existing entry” chosen"),
  (r"04-entry-top", lambda m: "Entry top: cover photo, title, summary"),
  (r"04-entry-table-b", lambda m: "Entry scrolled further: table and the second photo"),
  (r"04-entry-table", lambda m: "Entry body: text, photo and table together"),
  (r"06-list-hidden", lambda m: "List with the private entry hidden"),
  (r"06-menu-show-private-before", lambda m: "≡ menu with “Show private” (before)"),
  (r"06-faceid-prompt-private", lambda m: "Face ID prompt for “Show private”"),
  (r"06-menu-show-private-after", lambda m: "≡ menu after Face ID: “Hide private” (after)"),
  (r"06-list-shown-private-row", lambda m: "List with the private entry showing"),
  (r"06-list-shown", lambda m: "List after unlocking"),
  (r"06-applock-prompt", lambda m: "Face ID lock on open, with the Face ID prompt"),
  (r"06-applock-unlocked", lambda m: "After unlocking"),
  (r"07-entry-menu", lambda m: "Entry menu with Export…"),
  (r"07-export-sheet", lambda m: "Export sheet with “Save to folder…”"),
  (r"07-folder-picker-in-folder", lambda m: "Folder picker inside “AirPad notes”"),
  (r"07-folder-picker", lambda m: "System folder picker"),
  (r"07-export-saved", lambda m: "Export sheet after saving"),
  (r"07-files-attachments", lambda m: "Files: the attachments folder"),
  (r"07-files-folder", lambda m: "Files: the .md and its attachments folder"),
  (r"08-settings-models-section", lambda m: "Settings → Models, the “Your own models” row"),
  (r"08-settings", lambda m: "Settings"),
  (r"08-your-own-models", lambda m: "Your own models: endpoint and “Ollama 0.13.2” detected"),
  (r"08-models-list-b", lambda m: "Models list scrolled: curated downloads"),
  (r"08-models-list", lambda m: "Models list: installed, in memory, curated names"),
  (r"clip-map-glide-(slow|normal)-(dark|light)", lambda m: f"Clip: Map glide, {m[1]} pan, {m[2]}"),
  (r"clip-open-entry-(dark|light)", lambda m: f"Clip: Map → List → the entry, scrolled to the table, {m[1]}"),
  (r"clip-share-from-safari-(dark|light)", lambda m: f"Clip: Safari → Share → AirPad’s sheet, {m[1]}"),
  (r"clip-librarian-stream-(dark|light)", lambda m: f"Clip: the Librarian answers, streaming to the end, {m[1]}"),
  (r"clip-look-(\w+)-(dark|light)-([\w-]+)", lambda m: f"Clip: {m[1].title()} look, {m[2]}, background “{m[3]}”, settling then a gentle drift"),
]
def what(stem):
    ap = ""
    m = re.match(r"(0[2-46-8]-.*)-(light|dark)$", stem)
    if m: stem, ap = m[1], m[2]
    base = re.sub(r"-(zoomed|start)$", "", stem)
    for pat, f in WHAT:
        m = re.fullmatch(pat, base)
        if m and f: return f(m) + (" (pinched out: several territories)" if stem.endswith("-zoomed") else "") + (f", {ap}" if ap else "")
    return ""
def probe(p):
    if p.endswith(".png"):
        o = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", p], capture_output=True, text=True).stdout
        w, h = re.findall(r"pixel\w+: (\d+)", o); return f"{w}×{h}", ""
    j = json.loads(subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
        "stream=width,height,nb_read_frames,r_frame_rate,avg_frame_rate:format=duration", "-of", "json", p], capture_output=True, text=True).stdout)
    s = j["streams"][0]; d = float(j["format"]["duration"]); n = int(s["nb_read_frames"])
    return f"{s['width']}×{s['height']}", f"{d:.1f} s · {n} frames · {n/d:.1f} fps avg"
rows = []
for dp, _, fs in sorted(os.walk(root)):
    for f in sorted(fs):
        if not re.search(r"\.(png|mov|mp4)$", f): continue
        p = os.path.join(dp, f); rel = os.path.relpath(p, root); size, extra = probe(p)
        rows.append((rel, size, extra, what(os.path.splitext(f)[0])))
with open(os.path.join(root, "manifest.md"), "w") as out:
    out.write("# 1.1 store assets: manifest\n\nEvery file, its size in pixels, and what it shows. Clips: duration, the frames the "
              "Simulator actually delivered, and their average rate (it records only frames that change, so a still stretch "
              "lowers the average; see `clips/fps.md` for the rate during motion).\n\n| File | Pixels | Clip | Shows |\n|---|---|---|---|\n")
    for r in rows: out.write(f"| `{r[0]}` | {r[1]} | {r[2]} | {r[3]} |\n")
print(len(rows), "files")
