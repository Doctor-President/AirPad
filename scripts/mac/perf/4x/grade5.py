#!/usr/bin/env python3
"""Sweep 2b · step 5 re-proofs (verifier 4 and 6) with real events — grade one run. Numbers / kinds / ids only.
   grade5.py sheet <run dir>   2b-5-sheetfield.steps: a click in the Settings sheet keeps the keys in the sheet's field
   grade5.py cmdo  <run dir>   2b-5-cmdo-space.steps: ⌘O in the viewer then Space ~20 ms later still opens a copy
exit 1 on any FAIL"""
import re, sys, pathlib, datetime
what, d = sys.argv[1], pathlib.Path(sys.argv[2])
steps = []
for l in (d / "rperf.txt").read_text(errors="replace").splitlines():
    m = re.match(r"(\S+) (\S+) (.*?)\bat (\d{12,})", l)
    if m: steps.append((m[1], m[2], int(m[4]), m[3].strip()))
    elif re.match(r"\S+ \S+ NOT FOUND", l): steps.append((l.split()[0], "NOTFOUND", None, l))
ev = []
for l in (d / "app.log").read_text(errors="replace").splitlines():
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) .*?\[4x\] (\S+) (.*)$", l)
    if m: ev.append((datetime.datetime.strptime(m[1], "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000, m[2], m[3]))
def at(label): return next((s for s in steps if s[0] == label), None)
def txt(label): s = at(label); return s[3] if s else "(step missing)"
def win(a, b):
    sa, sb = at(a), at(b)
    if not sa or sa[2] is None: return None
    t1 = sb[2] if sb and sb[2] is not None else float("inf")
    return [e for e in ev if sa[2] - 50 <= e[0] < t1]
def has(w, pat): return w is not None and any(re.search(pat, f"{e[1]} {e[2]}") for e in w)
rows = []
def row(name, ok, detail=""): rows.append(ok); print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {detail}" if detail else ""))
nf = [s[0] for s in steps if s[1] == "NOTFOUND"]
if nf: print("NOT FOUND steps:", " ".join(nf))
if what == "sheet":
    row("sheet open on Web search (switch present)", "absent" not in txt("s0"), txt("s0"))
    f1 = txt("s1f"); row("S1 a click in the key field focuses it", "AXTextField" in f1, f1)
    for lab, name in (("s2f", "S2 a click on the field's label (in the sheet)"), ("s3f", "S3 a click beside the switch (in the sheet)")):
        row(f"{name} leaves the keys in the sheet's field", txt(lab) == f1 and "AXTextField" in f1, txt(lab))
    row("S3b the switch was not toggled", txt("s3v").endswith("=1"), txt("s3v"))
    w = win("s-label", "s3v")
    fired = [e[2] for e in (w or []) if e[1] == "4.1" and "click outside ends editing" in e[2]]
    row("S2b the click-away rule did not act on a click inside the sheet (app log)", w is not None and not fired, "; ".join(fired) or "no 4.1 line")
    # Information only: Esc does not close this pane even with no click-away (control 2b-5-sheetfield-ctl.steps, 2026-11-24).
    print(f"info Esc after the clicks: 1st {txt('s4')} · focus {txt('s4f')} · 2nd {txt('s5')} · row {txt('s5r')}")
else:
    for v in ("a", "b"):
        opener = f"{v}-click" if v == "a" else f"{v}-space"
        space = "a-space" if v == "a" else "b-space2"
        opened = has(win(opener, f"{v}-cmdO"), r"4\.3 viewer open items")
        if v == "b" and not opened: print("info B: no new viewer (A's viewer was still open: A's Space went to Preview); B not graded"); continue
        row(f"{v.upper()} precondition: the viewer opened", opened)
        w = win(f"{v}-cmdO", f"{v}-front")
        lines = [e[2] for e in (w or []) if e[1] == "4.4"]
        row(f"{v.upper()} ⌘O then Space: a copy is opened, the stored file never handed out",
            any("open a copy:" in x and "handed out: no" in x for x in lines), "; ".join(lines) or "no 4.4 line")
        # Information only: ⌘O hands the copy to Preview, which comes to the front ~0.1 s later, so a real Space after it
        # lands in Preview (2026-11-24: the copy was done 3 ms after ⌘O, before any real-key Space could reach the viewer).
        print(f"info {v.upper()} the Space closed AirPad's viewer: {'yes' if has(win(space, f'{v}-front'), r'4.3 viewer closed') else 'no'}")
        sa, sb = at(f"{v}-cmdO"), at(space)
        if sa and sb and sa[2] and sb[2]: print(f"   {v.upper()} ⌘O step → Space step: {sb[2] - sa[2]} ms")
print(f"\n{'PASS' if all(rows) else 'FAIL'} {sum(rows)}/{len(rows)}"); sys.exit(0 if all(rows) else 1)
