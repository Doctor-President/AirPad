#!/usr/bin/env python3
"""Sweep 2b · 4.x — grade a run.sh run dir from its app.log "[4x]" lines (numbers, kinds and ids only).
   grade4x.py <run dir> photos|document|keeper|keeper-off
   grade4x.py <run B dir> thumbs <run A dir>
Prints one PASS/FAIL row per check and a total; exit 1 on any FAIL."""
import re, sys, pathlib

def lines(d):
    p = pathlib.Path(d) / "app.log"
    out = []
    for l in p.read_text(errors="replace").splitlines():
        m = re.search(r"\[4x\] (\S+) (.*)$", l)
        if m: out.append((m.group(1), m.group(2)))
    return out

rows = []
def row(name, ok, detail=""):
    rows.append(ok); print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {detail}" if detail else ""))

def seq(ev, *pats):
    """True when the patterns occur in this order (each after the previous match)."""
    i = 0
    for p in pats:
        while i < len(ev) and not re.search(p, f"{ev[i][0]} {ev[i][1]}"): i += 1
        if i == len(ev): return False
        i += 1
    return True

d, kind = sys.argv[1], sys.argv[2]
ev = lines(d)
if kind in ("photos", "document"):
    k = "photo" if kind == "photos" else "document"
    opened = [e for e in ev if e[0] == "4x" and e[1].startswith("open ")]
    row("entry opened", bool(opened) and "none" not in opened[0][1], opened[0][1] if opened else "no -Open4x line")
    row("H1 highlight on hover", any(e[0] == "4.2" and e[1].startswith(f"highlight on {k}") for e in ev))
    row("H2 ␣ hint after a rest", any(e[0] == "4.2" and e[1].startswith(f"keycap hint {k}") for e in ev))
    row("H1b highlight off when the pointer leaves", any(e[0] == "4.2" and e[1].startswith(f"highlight off {k}") for e in ev))
    row("Q1 Space opens Quick Look", seq(ev, rf"4\.2 space opens {k}", r"4\.3 viewer open items"))
    if kind == "photos":
        n = [int(m.group(1)) for e in ev if e[0] == "4.3" for m in [re.search(r"viewer open items (\d+)", e[1])] if m]
        row("Q1b the entry's photos (more than one)", bool(n) and max(n) > 1, f"items {n}")
        row("Q2 → / ← step", seq(ev, r"arrow right → \d+", r"arrow right → \d+", r"arrow left → \d+"))
    row("Q3 Space closes", seq(ev, r"4\.3 viewer open items", r"space closes the viewer", r"4\.3 viewer closed"))
    row("Q4 click = Quick Look (a second viewer)", len([e for e in ev if e[0] == "4.3" and e[1].startswith("viewer open items")]) >= 2)
    row("Q5 Esc closes", seq(ev, r"esc closes the viewer", r"4\.3 viewer closed"))
    o = [e[1] for e in ev if e[0] == "4.4"]
    row("O1 ⌘O opens a COPY, never the stored file", any("open a copy:" in x and "handed out: no" in x for x in o), "; ".join(o) or "no 4.4 line")
elif kind == "thumbs":
    a = lines(sys.argv[3])
    def last(ev):
        t = [e[1] for e in ev if e[0] == "4.5" and e[1].startswith("thumbs ")]
        return dict(re.findall(r"([a-z-]+) (\d+)", t[-1])) if t else {}
    A, B = last(a), last(ev)
    row("A (empty disk cache) decoded originals and wrote them", int(A.get("original-decodes", 0)) > 0 and int(A.get("writes", 0)) > 0, str(A))
    row("B (cold launch after a build) read from disk", int(B.get("disk-hits", 0)) > 0, str(B))
    row("B decoded NO original", int(B.get("original-decodes", 1)) == 0, f"B original-decodes {B.get('original-decodes')}")
    mb = re.findall(r"files (\d+) MB cap (\d+) MB", " ".join(e[1] for e in ev if e[0] == "4.5"))
    row("on-disk size within the cap", bool(mb) and int(mb[-1][0]) <= int(mb[-1][1]), f"{mb[-1][0]} MB of {mb[-1][1]} MB" if mb else "no line")
elif kind == "keeper":
    s = [e[1] for e in ev if e[0] == "4.6"]
    row("launch sweep ran", any(x.startswith("sweep launch:") for x in s), next((x for x in s if x.startswith("sweep launch:")), "none"))
    batches = [x for x in s if x.startswith("batch ")]
    steps = [int(m.group(1)) for x in batches for m in [re.search(r"requested (\d+)/", x)] if m]
    ok = bool(steps) and all(b - a <= 16 for a, b in zip([0] + steps, steps))
    row("throttled in batches of ≤ 16", ok, f"{len(batches)} batches, requested {steps[-1] if steps else 0}")
    end = next((x for x in s if x.startswith("sweep launch end:")), "")
    row("sweep finished off the main thread", "main thread no" in end, end)
elif kind == "keeper-off":
    s = [e[1] for e in ev if e[0] == "4.6"]
    row("switch off: no sweep, no request", any(x.startswith("switch off: no sweep") for x in s) and not any(x.startswith("batch ") for x in s), "; ".join(s))
print(f"\n{'PASS' if all(rows) else 'FAIL'} {sum(rows)}/{len(rows)}")
sys.exit(0 if all(rows) else 1)
