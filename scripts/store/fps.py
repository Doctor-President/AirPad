#!/usr/bin/env python3
# 1.1 store — the frame rate each clip really has: average over the whole clip, and during motion (runs of frames < 100 ms
# apart), from the frame timestamps. Usage: fps.py <clips dir> → <clips dir>/fps.md
import json, os, statistics, subprocess, sys
d = sys.argv[1]; rows = []
for f in sorted(os.listdir(d)):
    if not f.endswith(".mov"): continue
    j = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
        "-show_entries", "stream=width,height,r_frame_rate,codec_name", "-of", "json", os.path.join(d, f)], capture_output=True, text=True).stdout)
    t = [float(x["pts_time"]) for x in j["frames"] if "pts_time" in x]; s = j["streams"][0]
    dt = [b - a for a, b in zip(t, t[1:]) if b > a]
    dur = t[-1] - t[0] if len(t) > 1 else 0
    # frames in each whole second of the clip; "in motion" = seconds with ≥ 10 frames (a still screen sends almost none)
    per = [sum(1 for x in t if k <= x - t[0] < k + 1) for k in range(int(dur))]
    moving = [c for c in per if c >= 10]
    rows.append((f, f"{s['width']}×{s['height']}", s["codec_name"], f"{dur:.1f}", len(t), f"{len(t)/dur:.1f}" if dur else "-",
                 f"{statistics.median(moving):.0f}" if moving else "-", f"{max(per)}" if per else "-"))
with open(os.path.join(d, "fps.md"), "w") as o:
    o.write("# Clip frame rates (measured from the frame timestamps)\n\n| Clip | Pixels | Codec | Seconds | Frames | Avg fps (whole clip) | Median frames/s while moving | Busiest second |\n|---|---|---|---|---|---|---|---|\n")
    for r in rows: o.write("| " + " | ".join(map(str, r)) + " |\n")
print(open(os.path.join(d, "fps.md")).read())
