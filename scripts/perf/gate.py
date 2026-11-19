#!/usr/bin/env python3
"""gate.py — the standing speed gate (Mac perf audit P4).

  gate.py --mac <table.json> [<table.json> …] [--iphone <table.json>] [--rest <rest.json>] [--phases <phases.json>] [--out gate.md]

Reads the per-action tables steps.py wrote (`--json`) for the Mac runs (scripts/mac/perf/gate.sh) and, when given,
the iPhone run (scripts/perf/ios_parity.sh), and prints one small table with PASS / FAIL per action against the
budgets below. Exit status 1 when anything fails.

Budgets (directive 2026-11-18):
  input → visible            ≤ 50 ms p95     (Mac: the first changed frame on screen, measured by rperf)
  view / panel switch settled ≤ 150 ms p95   (labels in SWITCHES)
  no stall                   > 100 ms        (main thread, any action)
  scrolling                  at the display's rate (≥ 90 % of it; ≤ 10 % late frames)
  the Map at rest            within ~1 s of any change (phases.json: 0 Map frames a second 2–4 s after each change)
  every screen at rest       main thread busy ≤ 3 % of the time (rest.json)
  no growth over the soak    memory ≤ +10 % first → last cycle; frame p95 not worse than +20 % (phases.json)
  every action               ≤ the iPhone's time (app-side input → main thread free, p50; 10 ms grace)
"""
import json, sys

SWITCHES = ("view-", "place-", "librarian-", "settings-", "open-", "close-", "theme-", "look-", "gravity-", "fluted-", "font-")
SCROLL = ("scroll", "scrollmove", "drag", "move", "swipe")


def merge(paths):
    acts, dev = {}, None
    for p in paths:
        t = json.load(open(p))
        dev = dev or t.get("device")
        for k, v in t["actions"].items():
            if k in ("rest", "library", "note-click", "ask-click", "search-click", "ask-clear", "search-clear"): continue
            acts[k] = v   # later files win (re-runs)
    return acts, dev


def f(x, unit=""):
    return "-" if x is None else f"{x:.0f}{unit}"


def main(a):
    def arg(name, many=False):
        if name not in a: return [] if many else None
        i = a.index(name) + 1
        out = []
        while i < len(a) and not a[i].startswith("--"):
            out.append(a[i]); i += 1
        return out if many else (out[0] if out else None)
    mac, dev = merge(arg("--mac", True))
    ios = merge([arg("--iphone")])[0] if arg("--iphone") else {}
    hz = (dev or {}).get("maxFPS", 60)
    low = (dev or {}).get("lowPower")
    rows, fails = [], 0
    for k, m in mac.items():
        checks = []
        scroll = m.get("verb") in SCROLL
        if scroll:
            fps, late = m.get("fps"), m.get("late_pct")
            target = hz * 0.9
            ok = fps is not None and fps >= target and (late or 0) <= 10
            checks.append(("scroll rate", ok, f"{f(fps)} fps of {hz}, {f(late)}% late"))
        else:
            v = m.get("visible_p95")
            # Typing: one glyph is below the screen comparison's threshold, so a key's "visible" time is not reliable;
            # typed steps are judged on stalls only.
            if v is not None and m.get("verb") != "key": checks.append(("visible ≤ 50", v <= 50, f"{f(v)} ms"))
            if k.startswith(SWITCHES):
                s = m.get("settled_p95")
                if s is not None: checks.append(("settled ≤ 150", s <= 150, f"{f(s)} ms"))
        checks.append(("no stall > 100", m.get("hang_max", 0) <= 100, f"{f(m.get('hang_max'))} ms"))
        i = ios.get(k)
        if i and not scroll and m.get("resp_p50") is not None and i.get("resp_p50") is not None:
            checks.append(("≤ iPhone", m["resp_p50"] <= i["resp_p50"] + 10, f"{f(m['resp_p50'])} vs {f(i['resp_p50'])} ms"))
        if i and scroll and m.get("late_pct") is not None and i.get("late_pct") is not None:
            checks.append(("≤ iPhone", m["late_pct"] <= i["late_pct"] + 5, f"{f(m['late_pct'])}% vs {f(i['late_pct'])}% late"))
        bad = [c for c in checks if not c[1]]
        fails += len(bad)
        rows.append((k, m, i, checks, bad))
    extra = []
    phases = arg("--phases")   # scripts/perf/phases.py --json (p0-appearance.sh): the Map after each change + the soak
    ph = json.load(open(phases)) if phases else {}
    if ph.get("rest"):
        bad_rest = {k: v for k, v in ph["rest"].items() if v > 0}
        fails += 1 if bad_rest else 0
        extra.append(f"| Map at rest after each appearance change ({len(ph['rest'])} changes) | {'FAIL' if bad_rest else 'PASS'} | "
                     + (", ".join(f"{k}: {v:.0f} frames a second" for k, v in bad_rest.items()) or "0 Map frames a second 2–4 s after every change") + " |")
    rest = arg("--rest")       # scripts/perf/rest.py --json (rest.sh): each screen with nothing happening
    if rest:
        r = json.load(open(rest))
        for name, v in r.items():
            ok = v["busy"] <= 3
            fails += 0 if ok else 1
            extra.append(f"| at rest: {name} | {'PASS' if ok else 'FAIL'} | main thread busy {v['busy']:.0f} % of the time, {v['wakes']:.0f} wake-ups a second, CPU {v['cpu']:.0f} % of one core |")
    if ph.get("soak"):
        s = ph["soak"]
        ok = s["mem_growth_pct"] <= 10 and s["p95_growth_pct"] <= 20
        fails += 0 if ok else 1
        extra.append(f"| soak ({s['minutes']:.0f} min) | {'PASS' if ok else 'FAIL'} | memory {s['mem_first']} → {s['mem_last']} MB ({s['mem_growth_pct']:+.0f}%), frame p95 {s['p95_first']:.1f} → {s['p95_last']:.1f} ms ({s['p95_growth_pct']:+.0f}%) |")
    lines = [f"Speed gate · display {hz} Hz" + (" · Low Power Mode ON (the Mac draws at most 60 a second)" if low else ""), "",
             "| action | result | Mac: screen visible / settled p95 | Mac: app response p50 | iPhone Sim: app response p50 | longest stall | failed |",
             "|---|---|---|---|---|---|---|"]
    for k, m, i, checks, bad in rows:
        res = "PASS" if not bad else "FAIL"
        scroll = m.get("verb") in SCROLL
        col = m.get("frames", "-") if scroll else f"{f(m.get('visible_p95'))} / {f(m.get('settled_p95'))} ms"
        ic = "-" if not i else (i.get("frames", "-") if scroll else f(i.get("resp_p50"), " ms"))
        lines.append(f"| {k} | {res} | {col} | {f(m.get('resp_p50'), ' ms') if not scroll else '-'} | {ic} | {f(m.get('hang_max'))} ms | {'; '.join(f'{c[0]}: {c[2]}' for c in bad) or '-'} |")
    if extra:
        lines += ["", "| check | result | detail |", "|---|---|---|"] + extra
    lines += ["", f"{'FAIL' if fails else 'PASS'}: {fails} budget(s) missed over {len(rows)} actions."]
    text = "\n".join(lines)
    print(text)
    out = arg("--out")
    if out: open(out, "w").write(text + "\n")
    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    sys.exit(main(sys.argv[1:]))
