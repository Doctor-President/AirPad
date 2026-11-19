#!/usr/bin/env python3
"""explain.py — turn a performance recording (Settings › About › Performance recorder; Mac ⌃⌥⌘P, iPhone three-finger
long-press) into plain language: what was slow and why.

  explain.py <perf-*.json> [--from T --to T] [--detail] [--json]

Also imported by the speed gate (scripts/perf/gate.py): `load`, `window`, `summarise`.
A recording holds timings, view type names and code symbols only; nothing from the library.
"""
import json, sys, subprocess, collections, re

# Where a main-thread sample is spending its time, read from the innermost frame outwards. First match wins.
FAMILIES = [
    ("hover / hit-testing",      r"hitTest|HitTest|HoverGesture|UIHoverGestureRecognizer|PlatformHitTesting|ViewResponder|pointInside|_UIHoverEvent|containsGlobalPoints|bindEvent"),
    ("accessibility (harness)",  r"AXRuntime|accessibility|Accessibility|_AX|UIAccessibility"),
    ("text layout",              r"CoreText|CTLine|CTFrame|CTTypesetter|NSTextLayoutManager|NSLayoutManager|TextKit|UIFoundation|NSAttributedString|StyledTextLayout|ResolvedStyledText|NSStringDrawing|TextLayout|CTFont|sizeThatFits.*Text|TLine|TRun"),
    ("image decode / draw",      r"ImageIO|CGImage|IIO|vImage|CGContextDraw|UIGraphicsImageRenderer|CoreGraphics.*[Rr]ender|CGBitmapContext|AppleJPEG|png_|ImageRenderer"),
    ("file / JSON",              r"JSONDecoder|JSONEncoder|JSONSerialization|NSData.*contentsOf|\bread\b|\bopen\b|\bpread\b|NSFileManager|FileManager|NSFileCoordinator|__open|_dispatch_io|PropertyList|NSKeyedArchiver|stat\$|getattrlist"),
    ("Map (SpriteKit)",          r"SpriteKit|SKScene|SKView|SKNode|SKSprite|SKC|SKShader|CorpusPhysicsScene|jet_|SKRenderer"),
    ("menu bar rebuild",         r"UIMenu|NSMenu|buildMenu|_UIMenuBar|UICommand|validateCommand|UIKeyCommand"),
    ("Core Animation commit",    r"CA::Transaction|CA::Layer|CA::Context|CALayer|CABackingStore|CA::Render|layoutSublayers|display_if_needed|CAMetalLayer"),
    ("SwiftUI layout",           r"StackLayout|LayoutComputer|LayoutProxy|sizeThatFits|placeSubviews|LayoutEngine|_VStackLayout|_HStackLayout|LazyLayout|LazyVGrid|LazyVStack|LazySubviewPlacements|GeometryReader|ViewSizeCache|_FlexFrameLayout|_PaddingLayout|ScrollViewLayout|IncrementalChildPlacements"),
    ("SwiftUI view updates",     r"AttributeGraph|AG::|ViewGraph|SwiftUI|DynamicBody|StatefulRule|_ViewList|ForEachState|GraphHost|ObservationRegistrar|Observation"),
    ("UIKit views",              r"UIView|UIKitCore|UIScrollView|UINavigation|UIHosting|layoutSubviews|UIWindow|UICollectionView"),
    ("Metal / GPU submit",       r"Metal|MTL|AGX|IOGPU|IOSurface|RenderBox|RB::"),
    ("memory",                   r"malloc|free\b|swift_release|swift_retain|swift_dealloc|objc_release|objc_retain|szone|nanov2|_xzm|swift_allocObject|bzero|memmove|memcpy"),
    ("waiting (blocked)",        r"mach_msg|semaphore_wait|__psynch|__ulock_wait|dispatch_sync|_dispatch_semaphore|xpc_connection_send_message_with_reply_sync|kevent"),
]
FAMILIES = [(n, re.compile(p)) for n, p in FAMILIES]
NOISE = re.compile(r"^main$|^\$?s?6AirPad0aB3AppV5\$main|__swift_instantiate|outlined |initializeWithCopy|assignWithCopy|destroy for|value witness|type metadata|protocol witness for static PreferenceKey|lazy protocol witness|^partial apply|thunk for|AirPadApp")
APP_IMAGES = ("AirPad", "AirPad.debug.dylib", "AirPadMacA")


def load(path, symbolicate=True):
    d = json.load(open(path))
    d["_path"] = path
    if symbolicate:
        atos(d)
    return d


def atos(d):
    """Exact symbols with `atos` where the image is on this Mac (the recording's own names come from dladdr, which
    only knows exported symbols: fine for AirPad's code, approximate inside system frameworks). Set AIRPAD_DSYM to an
    app's .dSYM for file:line in AirPad's code."""
    import os
    by_img = collections.defaultdict(list)
    for e in d["symbols"]:
        if e.get("i"): by_img[e["i"]].append(e)
    for img, entries in by_img.items():
        info = d["images"].get(img)
        if not isinstance(info, dict): continue
        path = info["path"]
        dsym = os.environ.get("AIRPAD_DSYM")
        if img in APP_IMAGES and dsym and os.path.exists(dsym): path = dsym
        elif not os.path.exists(path) and not path.startswith(("/System/", "/usr/lib/")): continue
        addrs = ["0x" + e["a"] for e in entries]
        try:
            out = subprocess.run(["atos", "-o", path, "-l", "0x" + info["base"]] + addrs, capture_output=True, text=True, timeout=60).stdout.split("\n")
        except Exception:
            continue
        for e, line in zip(entries, out):
            m = re.match(r"(.+?) \(in .+?\)( \((.+?)\))?( \+ \d+)?$", line.strip())
            if m and not m.group(1).startswith("0x"):
                e["s"] = m.group(1); e["atos"] = True
                if m.group(3): e["l"] = m.group(3)


def demangle(names):
    names = list(names)
    if not names:
        return {}
    try:
        out = subprocess.run(["xcrun", "swift-demangle", "--simplified"], input="\n".join(names), capture_output=True, text=True, timeout=30).stdout.split("\n")
        return {n: (o or n) for n, o in zip(names, out)}
    except Exception:
        return {n: n for n in names}


def window(d, t0=None, t1=None):
    """A copy of the recording cut to [t0, t1] (recording clock, seconds)."""
    t0 = d["frames"][0][0] if t0 is None and d["frames"] else (t0 or 0)
    t1 = d["now"] if t1 is None else t1
    w = dict(d)
    for k in ("frames", "spans", "inputs", "marks", "intervals", "bodies", "map", "vitals"):
        w[k] = [r for r in d[k] if t0 <= r[0] <= t1]
    w["samples"] = [s for s in d["samples"] if t0 <= s["t"] <= t1]
    w["_t0"], w["_t1"] = t0, t1
    return w


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, max(0, int(round(len(v) * p + 0.5)) - 1))] if v else None


def family(d, sample):
    syms = d["symbols"]
    for i in sample["f"]:
        e = syms[i]
        text = (e.get("s") or "") + " " + (e.get("i") or "")
        for name, rx in FAMILIES:
            if rx.search(text):
                return name
    return "other"


def app_frame(d, sample):
    """The innermost frame in AirPad's own code (what of ours is on the stack)."""
    syms = d["symbols"]
    for i in sample["f"]:
        e = syms[i]
        if e.get("i") in APP_IMAGES and e.get("s") and not NOISE.search(e["s"]):
            return e["s"]
    return None


def summarise(d):
    """Numbers for one window of a recording."""
    out = {}
    fr = [f[1] for f in d["frames"]]
    dev = d["device"]
    hz = dev.get("maxFPS", 60)
    span = (d["frames"][-1][0] - d["frames"][0][0]) if len(d["frames"]) > 1 else 0
    out["seconds"] = round(span, 2)
    out["display_hz"] = hz
    if fr:
        out["fps"] = round(len(fr) / span, 1) if span > 0 else None
        out["frame_p50"] = pct(fr, 0.5); out["frame_p95"] = pct(fr, 0.95); out["frame_max"] = max(fr)
        budget = 1000.0 / hz
        out["frames_late_pct"] = round(100.0 * sum(1 for x in fr if x > budget * 1.5) / len(fr), 1)
        out["frames_over_50"] = sum(1 for x in fr if x > 50)
    spans = d["spans"]
    out["busy_ms"] = round(sum(s[1] for s in spans))
    out["busy_pct"] = round(100.0 * out["busy_ms"] / (span * 1000), 1) if span > 0 else None
    hangs = [s for s in spans if s[1] >= 50]
    out["hangs_50"] = len(hangs); out["hangs_100"] = sum(1 for s in hangs if s[1] >= 100)
    out["hang_max"] = max((s[1] for s in hangs), default=0)
    out["hang_ms"] = round(sum(s[1] for s in hangs))
    # Families: every stack sample is ~10 ms of a busy main thread.
    fam = collections.Counter(); ours = collections.Counter()
    for s in d["samples"]:
        fam[family(d, s)] += 1
        a = app_frame(d, s)
        if a: ours[a] += 1
    n = sum(fam.values())
    out["samples"] = n
    out["families"] = [(k, round(100.0 * v / n)) for k, v in fam.most_common()] if n else []
    out["app_frames"] = ours.most_common(12)
    # Inputs: delivery delay (hardware event → the app got it) for presses / clicks / keys.
    discrete = [i for i in d["inputs"] if (i[2] == 1 and i[3] in (1, 3)) or (i[2] == 2 and i[3] == 1)]
    delays = [(i[1] - i[0]) * 1000 for i in discrete]
    out["inputs"] = len(discrete)
    out["input_delay_p50"] = pct(delays, 0.5); out["input_delay_p95"] = pct(delays, 0.95)
    # Response: from each press / key to the end of the busy stretch it started (the app's work before it could draw).
    resp = []
    for i in discrete:
        got = i[1]
        work = [s for s in spans if s[0] <= got + 0.012 and s[0] + s[1] / 1000 >= got - 0.002]
        nxt = [s for s in spans if got < s[0] <= got + 0.012]
        cand = work + nxt
        if cand:
            end = max(s[0] + s[1] / 1000 for s in cand)
            resp.append((end - i[0]) * 1000)
    out["response_p50"] = pct(resp, 0.5); out["response_p95"] = pct(resp, 0.95)
    out["hover_events"] = sum(1 for i in d["inputs"] if i[2] == 3)
    out["scroll_events"] = sum(1 for i in d["inputs"] if i[2] == 4)
    # View rebuilds.
    bodies = collections.Counter()
    for b in d["bodies"]:
        for k, v in b[1].items(): bodies[k] += v
    out["bodies"] = bodies.most_common(12)
    # Map.
    if d["map"]:
        out["map_fps"] = round(sum(m[1] for m in d["map"]) / max(1, len(d["map"])), 1)
        out["map_update_ms"] = round(sum(m[2] for m in d["map"]) / max(1, sum(m[1] for m in d["map"])), 2)
        out["map_update_max"] = round(max(m[3] for m in d["map"]), 1)
    else:
        out["map_fps"] = 0
    v = d["vitals"]
    if v:
        out["mem_start"] = round(v[0][1]); out["mem_end"] = round(v[-1][1]); out["mem_max"] = round(max(x[1] for x in v))
        out["cpu_avg"] = round(sum(x[2] for x in v) / len(v)); out["cpu_main_avg"] = round(sum(x[3] for x in v) / len(v))
        out["thermal_max"] = int(max(x[4] for x in v)); out["low_power"] = bool(v[-1][5])
    iv = collections.defaultdict(list)
    for i in d["intervals"]: iv[i[2]].append(i[1])
    out["intervals"] = sorted(((k, len(x), round(sum(x)), round(max(x))) for k, x in iv.items()), key=lambda r: -r[2])[:12]
    return out


def sentence(d, s):
    """The plain-language line."""
    dev = d["device"]
    where = ("Mac" if dev.get("mac") else "iPhone") + (" Simulator" if dev.get("simulator") else "")
    parts = [f"{where}, screen \"{d['screen']}\", {s['seconds']:.0f} s."]
    if s.get("fps") is not None:
        hz = s["display_hz"]
        if s["hangs_50"] == 0 and s["frames_late_pct"] < 5:
            parts.append(f"Smooth: frames at {s['fps']:.0f} a second on a {hz} Hz screen, no stall over 50 ms.")
        else:
            parts.append(f"The app's main thread stalled {s['hangs_50']} time(s) for 50 ms or more "
                         f"({s['hangs_100']} over 100 ms, the longest {s['hang_max']:.0f} ms; {s['hang_ms']} ms in all), "
                         f"and {s['frames_late_pct']:.0f}% of frames came late (median frame {s['frame_p50']:.1f} ms, 95th {s['frame_p95']:.1f} ms).")
    if s["families"]:
        top = [f"{k} {v}%" for k, v in s["families"][:4] if v >= 5]
        parts.append("Where the stalled time went: " + ", ".join(top) + ".")
    if s["app_frames"]:
        dm = demangle([a for a, _ in s["app_frames"][:3]])
        dm = {k: v for k, v in dm.items()}
        parts.append("AirPad code on the stack most often: " + "; ".join(f"{short(dm[a])} ({100 * c // max(1, s['samples'])}%)" for a, c in s["app_frames"][:3]) + ".")
    if s["bodies"]:
        parts.append("Views rebuilt most: " + ", ".join(f"{k} ×{v}" for k, v in s["bodies"][:5]) + ".")
    if s.get("input_delay_p95") is not None and s["input_delay_p95"] > 30:
        parts.append(f"Clicks / keys waited up to {s['input_delay_p95']:.0f} ms before the app even received them (the main thread was busy).")
    if s.get("map_fps"):
        parts.append(f"The Map drew {s['map_fps']:.0f} frames a second (its own work {s.get('map_update_ms', 0):.1f} ms a frame, worst {s.get('map_update_max', 0):.0f} ms).")
    if "mem_end" in s:
        parts.append(f"Memory {s['mem_start']} → {s['mem_end']} MB; CPU {s['cpu_avg']}% (main thread {s['cpu_main_avg']}%)."
                     + (" Low Power Mode was on." if s.get("low_power") else "")
                     + (" The device was hot (thermal state %d)." % s["thermal_max"] if s.get("thermal_max", 0) >= 2 else ""))
    return " ".join(parts)


def short(sym):
    sym = re.sub(r"\(extension in \w+\):", "", sym)
    sym = re.sub(r"closure #\d+ (\(.*?\) -> .*? )?in ", "closure in ", sym)
    return sym if len(sym) <= 90 else sym[:87] + "…"


def detail(d, s, top=14):
    lines = []
    lines.append(f"frames {len(d['frames'])} fps {s.get('fps')} p50 {s.get('frame_p50')} p95 {s.get('frame_p95')} max {s.get('frame_max')} late {s.get('frames_late_pct')}% >50ms {s.get('frames_over_50')}")
    lines.append(f"main busy {s['busy_ms']} ms ({s['busy_pct']}%) · stalls ≥50: {s['hangs_50']} ≥100: {s['hangs_100']} max {s['hang_max']:.0f} total {s['hang_ms']} ms")
    lines.append(f"inputs {s['inputs']} delivery p50/p95 {fmt(s['input_delay_p50'])}/{fmt(s['input_delay_p95'])} ms · response p50/p95 {fmt(s['response_p50'])}/{fmt(s['response_p95'])} ms · hover {s['hover_events']} scroll {s['scroll_events']}")
    lines.append("families: " + ", ".join(f"{k} {v}%" for k, v in s["families"]))
    dm = demangle([a for a, _ in s["app_frames"]])
    for a, c in s["app_frames"]:
        lines.append(f"  app {100 * c // max(1, s['samples']):3d}%  {short(dm[a])}")
    # The hottest leaf-side stacks.
    stacks = collections.Counter()
    for smp in d["samples"]:
        key = tuple((d["symbols"][i].get("s") or d["symbols"][i].get("i") or "?") for i in smp["f"][:7])
        stacks[key] += 1
    names = demangle({n for k, _ in stacks.most_common(top) for n in k})
    for k, c in stacks.most_common(top):
        lines.append(f"  stack {100 * c // max(1, s['samples']):3d}%  " + " < ".join(short(names.get(n, n))[:60] for n in k))
    if s["bodies"]: lines.append("bodies: " + ", ".join(f"{k} ×{v}" for k, v in s["bodies"]))
    if s["intervals"]: lines.append("intervals: " + ", ".join(f"{k} n{n} total {t} ms max {m}" for k, n, t, m in s["intervals"]))
    if d["marks"]: lines.append("marks: " + " | ".join(f"{m[0] - d['frames'][0][0]:.1f}s {m[1]}" for m in d["marks"][:40]) if d["frames"] else "")
    return "\n".join(lines)


def fmt(x):
    return "-" if x is None else f"{x:.0f}"


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__); sys.exit(2)
    d = load(a[0])
    t0 = float(a[a.index("--from") + 1]) if "--from" in a else None
    t1 = float(a[a.index("--to") + 1]) if "--to" in a else None
    w = window(d, t0, t1) if (t0 is not None or t1 is not None) else d
    s = summarise(w)
    if "--json" in a:
        print(json.dumps(s, indent=1))
    else:
        print(sentence(w, s))
        if "--detail" in a:
            print(detail(w, s))
