#!/usr/bin/env python3
"""2b-cards-select.py — grades the Cards spike's selection row (sweep 2b · 2.2) from one run.sh run of
2b-cards-select.steps (or 2b-cards-clickopens.steps with --opens).

  2b-cards-select.py <run dir> [--opens]

Joins rperf.txt (each step's wall time) to app.log's `MACCARDS at <ms> …` lines (arm B with -MacCardsLog YES: selection
changes as counts + item indices, opens, menus, band, settle; never entry text) and prints one PASS / FAIL per row."""
import re, sys, os

run = sys.argv[1]; opens = "--opens" in sys.argv
steps = []
for line in open(os.path.join(run, "rperf.txt"), encoding="utf-8", errors="replace"):
    m = re.match(r"(\S+) (\S+) visible \S+ settled \S+ frames \d+ at (\d+)", line)
    if m: steps.append((m[1], m[2], float(m[3])))
    elif " NOT FOUND " in line: steps.append((line.split()[0], "NOTFOUND", None))
events = []
for line in open(os.path.join(run, "app.log"), encoding="utf-8", errors="replace"):
    m = re.search(r"MACCARDS at (\d+) (\S+)(.*)", line)
    if m: events.append((float(m[1]), m[2], dict(re.findall(r"(\w+)=(\S+)", m[3]))))
if not events: print("no MACCARDS lines in app.log (arm B with -MacCardsLog YES, a DEBUG or PERFLOG build?)"); sys.exit(1)

def window(i):
    t0 = steps[i][2]
    if t0 is None: return []
    t1 = next((s[2] for s in steps[i + 1:] if s[2] is not None), float("inf"))
    return [e for e in events if t0 - 30 <= e[0] < t1 - 30]
def by(label): return [i for i, s in enumerate(steps) if s[0] == label]
def sel_after(label):
    """The selection (n, idx list) at the end of the step, or None if it didn't change in that step."""
    out = None
    for i in by(label):
        for e in window(i):
            if e[1] == "sel": out = (int(e[2]["n"]), [int(x) for x in e[2].get("idx", "").split(",") if x])
    return out
def has(label, kind, **kv):
    return any(e[1] == kind and all(e[2].get(k) == v for k, v in kv.items()) for i in by(label) for e in window(i))

total = max((int(e[2]["n"]) for e in events if e[1] == "items"), default=None)
rows = []
def row(name, ok, detail): rows.append((name, ok, detail))
missing = [s[0] for s in steps if s[1] == "NOTFOUND"]

if opens:
    row("click opens", has("o1-click", "open", via="click") or has("o1-click", "open", via="primary"), f"{[e[1:] for i in by('o1-click') for e in window(i)]}")
    a, b = sel_after("o2-cmdclick"), sel_after("o3-cmdclick")
    row("⌘-click selects without opening", bool(a and b and b[0] == a[0] + 1) and not has("o2-cmdclick", "open") and not has("o3-cmdclick", "open"), f"{a} → {b}")
    e = sel_after("o4-esc"); row("Esc clears", e is not None and e[0] == 0, f"{e}")
else:
    r1 = sel_after("r1-click"); row("1 click selects one", r1 is not None and r1[0] == 1, f"{r1}")
    r2 = sel_after("r2-cmdclick"); row("2 ⌘-click adds", r2 is not None and r2[0] == 2, f"{r2}")
    r3 = sel_after("r3-shiftclick"); row("3 ⇧-click range", r3 is not None and r3[0] >= 3 and r3[1] == list(range(r3[1][0], r3[1][0] + len(r3[1]))) if r3 and r3[1] else False, f"{r3}")
    r4 = sel_after("r4-cmdA"); row("4 ⌘A selects all", r4 is not None and (r4[0] == total if total else r4[0] >= 50), f"{r4 and r4[0]} of {total}")
    p, rt, dn, lf, up = (sel_after(l) for l in ("r5-pick", "r5-right", "r5-down", "r5-left", "r5-up"))
    ok5 = all(x and x[0] == 1 for x in (p, rt, dn, lf, up)) and rt[1][0] == p[1][0] + 1 and dn[1][0] > rt[1][0] and lf[1][0] == dn[1][0] - 1 and up[1][0] == p[1][0]
    row("5 arrows move the selection", ok5, f"{[x and x[1][:1] for x in (p, rt, dn, lf, up)]}")
    row("6 Return opens", has("r6-return", "open", via="return"), f"{[e[1:] for i in by('r6-return') for e in window(i)]}")
    escs = [sel_after(l) for l in ("r7-esc", "r7-esc2", "r7-esc3", "r7-esc4")]
    row("7 Esc clears", all(x is not None and x[0] == 0 for x in escs), f"{[x and x[0] for x in escs]}")
    r8 = sel_after("r8-box"); row("8 box drag selects", r8 is not None and r8[0] >= 2, f"{r8 and r8[0]} ({[e[2].get('via') for i in by('r8-box') for e in window(i) if e[1] == 'sel'][-1:]})")
    r9 = sel_after("r9-cmd2")
    menu = [e[2] for i in by("r9-menu") for e in window(i) if e[1] == "menu"]
    row("9 right-click on 3 selected → menu", bool(r9 and r9[0] == 3 and menu and menu[0].get("n") == "3"), f"selected {r9 and r9[0]}, menu {menu}")
    rows.append(("(extra) double-click opens", has("r6b-double", "open", via="double"), ""))
for name, ok, d in rows: print(f"{'PASS' if ok else 'FAIL'}  {name}   {d}")
n = sum(1 for r in rows if r[1] and not r[0].startswith("(extra)")); k = sum(1 for r in rows if not r[0].startswith("(extra)"))
print(f"\n{n} of {k}" + (f" · NOT FOUND: {missing}" if missing else ""))
