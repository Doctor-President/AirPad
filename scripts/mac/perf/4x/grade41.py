#!/usr/bin/env python3
"""Sweep 2b · 4.1 — grade one run of 2b-41-keys.steps (run41.sh): Space, ⌘O and Esc, per key, from app.log's "[4x]"
lines (NSLog time) joined to rperf.txt's step times ("at <epoch ms>") and its ax / focus lines. Numbers, kinds, ids and
the synthetic search text the steps typed only.
   grade41.py <run dir>        exit 1 on any FAIL"""
import re, sys, pathlib, datetime

d = pathlib.Path(sys.argv[1])
steps = []            # (label, verb, t_ms, rest)
for l in (d / "rperf.txt").read_text(errors="replace").splitlines():
    m = re.match(r"(\S+) (\S+) (.*?)\bat (\d{12,})", l)
    if m: steps.append((m[1], m[2], int(m[4]), m[3][:-1] if m[3].endswith(" ") else m[3]))   # keep a value's own spaces
    elif re.match(r"\S+ \S+ NOT FOUND", l): steps.append((l.split()[0], "NOTFOUND", None, l))
ev = []               # (t_ms, item, line)
for l in (d / "app.log").read_text(errors="replace").splitlines():
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) .*?\[4x\] (\S+) (.*)$", l)
    if m:
        t = datetime.datetime.strptime(m[1], "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000
        ev.append((t, m[2], m[3]))

def at(label):
    return next((s for s in steps if s[0] == label), None)
def win(a, b):
    sa, sb = at(a), at(b)
    if not sa or sa[2] is None: return None
    t1 = sb[2] if sb and sb[2] is not None else float("inf")
    return [e for e in ev if sa[2] - 50 <= e[0] < t1]
def has(w, pat): return w is not None and any(re.search(pat, f"{e[1]} {e[2]}") for e in w)
def val(label):
    s = at(label)
    if not s: return "(step missing)"
    m = re.search(r"=(.*)$", s[3]); return m[1] if m else s[3]
def focus(label):
    s = at(label); return s[3] if s else "-"

rows = []
def row(name, ok, detail=""):
    rows.append(ok); print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {detail}" if detail else ""))

tstate = at("search-type") is not None
print(f"state {'T (search field holding text, Librarian in Search)' if tstate else 'plain'} · focus at start: {focus('f0')} · field {val('f0s')!r}")
o = next((e[2] for e in ev if e[1] == "4x" and e[2].startswith("open ")), "no -Open4x line")
row("entry with a document opened", "none" not in o and o.startswith("open document"), o)
w = win("k1-space", "k1f")
row("K1 Space on a hovered document opens Quick Look", has(w, r"4\.2 space opens document") and has(w, r"4\.3 viewer open items"),
    f"focus {focus('k1f')} · field {val('f0s')!r} → {val('k1s')!r}")
if tstate: row("K1b the search text is untouched by that Space", val("k1s") == val("f0s"), f"{val('f0s')!r} → {val('k1s')!r}")
for k, a, b, what in (("K2", "k2-cmdO", "k2-front", "⌘O on a hovered document"),
                      ("K3", "k3-cmdO", "k3-front", "⌘O while the clicked document is in Quick Look"),
                      ("K4", "k4-cmdO", "k4-front", "⌘O after Quick Look closed (pointer still on it)")):
    w = win(a, b)
    lines = [e[2] for e in (w or []) if e[1] == "4.4"]
    row(f"{k} {what} opens a copy", any("open a copy:" in x and "handed out: no" in x for x in lines), "; ".join(lines) or "no 4.4 line")
row("K3 precondition: the click opened Quick Look", has(win("k3-click", "k3f"), r"4\.3 viewer open items"))
row("K3b Esc closed that Quick Look", has(win("k3-esc", "k4s"), r"4\.3 viewer closed"), f"field after {val('k4s')!r}")
on = val("k5-on"); a1 = at("k5-after"); a2 = at("k5-after2")
row("K5 precondition: selection active (Done shown)", "absent" not in on, f"{on} · focus {focus('k5f')} · field {val('k5s')!r}")
row("K5 Esc ends selection (first press)", a1 is not None and "absent" in a1[3], f"after 1st Esc: {a1[3] if a1 else '-'} · field {val('k5s2')!r} · "
    f"after 2nd Esc: {a2[3] if a2 else '-'}")
w = win("t1-type", "t1s")
row("T1 typing in the search field with a document hovered: Space types a space", val("t1s").endswith("a b"), f"field {val('t1s')!r} · document {val('t1d')}")
row("T1b … and opens no Quick Look", w is not None and not has(w, r"4\.3 viewer open items") and not has(w, r"space opens"))
print(f"\n{'PASS' if all(rows) else 'FAIL'} {sum(rows)}/{len(rows)}")
sys.exit(0 if all(rows) else 1)
