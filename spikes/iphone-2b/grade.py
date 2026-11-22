#!/usr/bin/env python3
"""Sweep 2b · 3.3 — turn the spike's results (phone and/or Mac) into the six answers of design.md §15, as markdown.

  python3 spikes/iphone-2b/grade.py --phone build/iphone-spike/results/<ts>/spike-results.json \
                                    --mac   build/iphone-spike/results/mac/spike-results.json  [--out answers.md]

Either side may be missing (a column then reads "—"). Reads only the results files: numbers, case IDs and the model
replies to the INVENTED cases.
"""
import argparse
import json
import statistics
import sys

# design.md §14, this Mac, nothing else running (medians, ms)
MAC_14 = {"sort": 560, "pick4": 1150, "pick12": 1630, "phraseFirstWord": 550, "phraseWhole": 800, "rewrite": 720}
SEARCH_MS = 900  # §14: search ≈ 0.9 s
DASH = "—"


def g(d, *path, default=None):
    for p in path:
        if isinstance(d, dict) and p in d:
            d = d[p]
        elif isinstance(d, list) and isinstance(p, int) and -len(d) <= p < len(d):
            d = d[p]
        else:
            return default
    return d


def fmt_ms(v):
    if v is None or v == -1:
        return DASH
    return f"{v / 1000:.2f} s"


def short(s, n=140):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def load(path):
    if not path:
        return None
    with open(path) as fh:
        return json.load(fh)


def q1(phone, mac):
    rows = ["## Q1 · `SystemLanguageModel.default.contextSize`", "", "| | Phone | Mac |", "|---|---|---|"]
    rows.append(f"| contextSize | {g(phone, 'apple', 'info', 'contextSize', default=DASH)} | {g(mac, 'apple', 'info', 'contextSize', default=DASH)} |")
    rows.append(f"| contentTagging contextSize | {g(phone, 'apple', 'info', 'contentTaggingContextSize', default=DASH)} | {g(mac, 'apple', 'info', 'contentTaggingContextSize', default=DASH)} |")
    rows.append(f"| availability | {g(phone, 'apple', 'info', 'availability', default=DASH)} | {g(mac, 'apple', 'info', 'availability', default=DASH)} |")
    return rows


def suite_cases(r, side):
    return {c["id"]: c for c in g(r, side, "suite", "cases", default=[]) or []}


def q2(phone, mac):
    rows = ["", "## Q2 · Which Apple model a third-party app gets", "", "| | Phone | Mac |", "|---|---|---|"]
    for key, label in [("variant", "variant.displayName"), ("isCore3", "== .core3"), ("isCoreAdvanced3", "== .coreAdvanced3"),
                       ("capabilities", "capabilities"), ("supportedLanguages", "supported languages")]:
        rows.append(f"| {label} | {short(g(phone, 'apple', 'info', key, default=DASH), 80)} | {short(g(mac, 'apple', 'info', key, default=DASH), 80)} |")
    rows.append(f"| Private Cloud Compute | {short(g(phone, 'apple', 'info', 'privateCloudCompute', 'availability', default=DASH), 60)} | {short(g(mac, 'apple', 'info', 'privateCloudCompute', 'availability', default=DASH), 60)} |")
    ps, ms = g(phone, "apple", "suite", "score"), g(mac, "apple", "suite", "score")
    rows.append(f"| 12-case suite (Apple) | {ps if ps is not None else DASH}/12 | {ms if ms is not None else DASH}/12 |")
    pc, mc = suite_cases(phone, "apple"), suite_cases(mac, "apple")
    if pc and mc:
        same_pick = sum(1 for k in pc if k in mc and pc[k].get("passage") == mc[k].get("passage"))
        same_ans = sum(1 for k in pc if k in mc and pc[k].get("answer", "").strip() == mc[k].get("answer", "").strip())
        rows.append(f"| same pick, phone vs Mac (greedy) | {same_pick}/{len(pc)} | |")
        rows.append(f"| identical answer text, phone vs Mac | {same_ans}/{len(pc)} | |")
        pv, mv = g(phone, "apple", "info", "variant"), g(mac, "apple", "info", "variant")
        verdict = ("same variant reported" if pv == mv else f"DIFFERENT variant reported ({pv} vs {mv})")
        verdict += "; same suite score" if ps == ms else f"; DIFFERENT suite score ({ps} vs {ms}): a different model"
        verdict += "; greedy answers identical on every case" if same_ans == len(pc) else f"; greedy answers differ on {len(pc) - same_ans} case(s)"
        rows += ["", f"**Reading:** {verdict}."]
    return rows


def q3(phone, mac):
    rows = ["", "## Q3 · Chain latency on the phone (fresh session per call, greedy)", "",
            "| Call | Phone cold (first of kind) | Phone warm median | Mac warm median | §14 Mac |", "|---|---|---|---|---|"]
    names = [("sort", "Sort (guided, one enum)"), ("pick4", "Pick from 4 passages (guided)"), ("pick12", "Pick from 12 passages (guided)"),
             ("phraseFirstWord", "Phrase: first word (streamed)"), ("phraseWhole", "Phrase: whole (≤ 80 tokens)"), ("rewrite", "Rewrite follow-up")]
    for key, label in names:
        rows.append(f"| {label} | {fmt_ms(g(phone, 'apple', 'latency', 'firstOfKind', key))} | {fmt_ms(g(phone, 'apple', 'latency', key, 'medianMs'))} | "
                    f"{fmt_ms(g(mac, 'apple', 'latency', key, 'medianMs'))} | {fmt_ms(MAC_14[key])} |")
    rows.append(f"| First call of the process | {fmt_ms(g(phone, 'apple', 'cold', 'ms'))} | | {fmt_ms(g(mac, 'apple', 'cold', 'ms'))} | |")
    for side, r in [("Phone", phone), ("Mac", mac)]:
        s, p, f, w = (g(r, "apple", "latency", k, "medianMs") for k in ("sort", "pick12", "phraseFirstWord", "phraseWhole"))
        if None not in (s, p, f, w):
            rows.append("")
            rows.append(f"**{side} chain (warm):** search 0.9 s + sort + pick12 + first word = **{(SEARCH_MS + s + p + f) / 1000:.1f} s** to the first word, "
                        f"{(SEARCH_MS + s + p + w) / 1000:.1f} s to the end (§14: 3.6 s / 3.9 s on the Mac; today's single call 5.1 s / 15.1 s).")
    for side, r in [("Phone", phone), ("Mac", mac)]:
        pt = g(r, "apple", "latency", "promptTokens")
        if pt:
            rows.append(f"- {side} prompt tokens: pick4 {pt.get('pick4', DASH)}, pick12 {pt.get('pick12', DASH)}; "
                        f"pick right {g(r, 'apple', 'latency', 'pickRightPassage', default=DASH)}, verbatim {g(r, 'apple', 'latency', 'pickSentenceVerbatim', default=DASH)}; "
                        f"errors {len(g(r, 'apple', 'latency', 'errors', default=[]) or [])}")
    return rows


def call_cell(c):
    if not c:
        return DASH
    if c.get("ok"):
        out = c.get("passage", c.get("reply", ""))
        return f"ok ({short(out, 60)})"
    e = c.get("error", {})
    return f"**{e.get('kind', '?')}**: `{short(e.get('type', ''), 60)}` {short(e.get('errorDescription') or e.get('description', ''), 120)}"


def q4(phone, mac):
    rows = ["", "## Q4 · Guided pick on sensitive-topic notes, default guardrails (Apple)", ""]
    for side, r in [("Phone", phone), ("Mac", mac)]:
        notes = g(r, "apple", "sensitive", "notes")
        if not notes:
            continue
        rows += [f"**{side}**", "", "| Note | Topic | Guided pick | Plain-text pick | Phrase | Phrase, permissive guardrails |", "|---|---|---|---|---|---|"]
        for n in notes:
            rows.append(f"| {n['id']} | {n['topic']} | {call_cell(n.get('guidedPick'))} | {call_cell(n.get('plainPick'))} | "
                        f"{call_cell(n.get('phrase'))} | {call_cell(n.get('phrasePermissive')) if 'phrasePermissive' in n else 'not needed'} |")
        gf, pf, of = (g(r, "apple", "sensitive", k) for k in ("guidedPickFailed", "plainPickFailed", "of"))
        sc = suite_cases(r, "apple")
        fallback_cases = [k for k, c in sc.items() if c.get("pickPath") == "fallback"]
        verdict = (f"guided pick failed on {gf} of {of} sensitive notes (plain-text pick failed on {pf}) → the plain-text fallback is REQUIRED on Apple"
                   if gf else f"guided pick answered all {of} sensitive notes → the fallback stays optional")
        if fallback_cases:
            verdict += f"; the suite fell back to plain text on {', '.join(fallback_cases)}"
        rows += ["", f"**Reading ({side}):** {verdict}.", ""]
    return rows


def turns_summary(r):
    turns = g(r, "mlx", "tenTurns", "turns", default=[]) or []
    ok = [t for t in turns if "error" not in t]
    med = lambda k: statistics.median([t[k] for t in ok if t.get(k, -1) not in (-1, None)]) if ok else None
    return turns, ok, med


def q5(phone, mac):
    rows = ["", "## Q5 · Qwen3.5 4B (MLX 4-bit) through FoundationModels' `LanguageModel` API", "", "| | Phone | Mac |", "|---|---|---|"]

    def both(label, f):
        rows.append(f"| {label} | {f(phone)} | {f(mac)} |")

    gb = lambda b: f"{b / 1e9:.2f} GB" if isinstance(b, (int, float)) and b > 0 else DASH
    both("weights on disk", lambda r: gb(g(r, "mlx", "weights", "bytesOnDisk")))
    both("same API: MLXLanguageModel compiled + linked", lambda r: "yes" if g(r, "mlx", "sameAPI", "mlxLanguageModelCompiled") else DASH)
    both("first load (weights)", lambda r: fmt_ms(g(r, "mlx", "load", "loadMs")) if g(r, "mlx", "load", "error") is None else f"FAILED: {short(g(r, 'mlx', 'load', 'error', 'description'), 100)}")
    both("first call after load (shader compile)", lambda r: fmt_ms(g(r, "mlx", "cold", "ms")))
    both("footprint before → after load", lambda r: f"{g(r, 'mlx', 'load', 'before', 'physFootprintMB', default='?')} → {g(r, 'mlx', 'load', 'after', 'physFootprintMB', default='?')} MB" if g(r, "mlx", "load") else DASH)
    both("peak footprint while running", lambda r: f"{g(r, 'mlx', 'memoryPeak', 'peakPhysFootprintMB')} MB" if g(r, "mlx", "memoryPeak") else DASH)
    both("least headroom (os_proc_available_memory)", lambda r: f"{g(r, 'mlx', 'memoryPeak', 'minAvailableMemoryMB')} MB" if (g(r, "mlx", "memoryPeak", "minAvailableMemoryMB") or -1) >= 0 else DASH)

    def speed(r, key, unit):
        _, ok, med = turns_summary(r)
        v = med(key) if ok else None
        return f"{v:.1f} {unit}" if v is not None else DASH
    both("decode speed, median of 10 turns", lambda r: speed(r, "tokensPerS", "tok/s"))
    both("words per second (whole turn)", lambda r: speed(r, "wordsPerS", "words/s"))
    both("time to first word, median", lambda r: fmt_ms(turns_summary(r)[2]("ttftMs")) if turns_summary(r)[1] else DASH)

    def thermal(r):
        turns = g(r, "mlx", "tenTurns", "turns", default=[]) or []
        seq = [g(t, "reading", "thermal") for t in turns]
        start = g(r, "mlx", "tenTurns", "start", "thermal")
        return f"{start} → {' '.join(s[:3] for s in seq if s)}" if start else DASH
    both("heat (thermalState start → per turn)", thermal)

    def battery(r):
        s, e = g(r, "mlx", "tenTurns", "start"), g(r, "mlx", "tenTurns", "end")
        if not s or "batteryLevel" not in s:
            return DASH
        return f"{s['batteryLevel'] * 100:.0f} % → {e.get('batteryLevel', 0) * 100:.0f} % ({s.get('batteryState')} → {e.get('batteryState')})"
    both("battery over ten turns", battery)

    def guided(r):
        a, b = g(r, "mlx", "latency", "guidedCalls"), g(r, "mlx", "suite", "guidedCalls")
        if not a and not b:
            return DASH
        ok = (a or {}).get("ok", 0) + (b or {}).get("ok", 0)
        err = (a or {}).get("errors", 0) + (b or {}).get("errors", 0)
        return f"{ok} ok, {err} errors" + (" → **works**" if ok and not err else " → **check errors**" if err else "")
    both("guided generation (@Generable sort/pick calls)", guided)

    def think(r):
        _, ok, _ = turns_summary(r)
        leaks = sum(1 for t in ok if t.get("thinkLeak")) + (g(r, "mlx", "suite", "thinkLeaks", default=0) or 0)
        rt = sum(max(0, t.get("reasoningTokens", 0)) for t in ok)
        return f"{leaks} <think> leaks, {rt} reasoning tokens" if ok else DASH
    both("thinking off", think)
    both("ten-turn errors", lambda r: str(sum(1 for t in (g(r, 'mlx', 'tenTurns', 'turns', default=[]) or []) if 'error' in t)) if g(r, "mlx", "tenTurns") else DASH)
    for side, r in [("Phone", phone), ("Mac", mac)]:
        st = g(r, "mlx", "tenTurns", "start", "batteryState")
        if st in ("charging", "full"):
            rows.append(f"\n_{side}: the battery was {st} (on USB) during the ten turns; the level change is not a drain figure._")
    return rows


def q6(phone, mac):
    rows = ["", "## Q6 · 12-case mini-suite: Qwen3.5 4B (MLX) against Apple, same cases", "",
            "| Case | Kind | Apple phone | MLX phone | Apple Mac | MLX Mac |", "|---|---|---|---|---|---|"]
    cols = [suite_cases(phone, "apple"), suite_cases(phone, "mlx"), suite_cases(mac, "apple"), suite_cases(mac, "mlx")]
    ids = next((list(c.keys()) for c in cols if c), [])

    def cell(c):
        if not c:
            return DASH
        mark = "pass" if c.get("pass") else f"FAIL ({c.get('reason', '')})"
        if c.get("pickPath") == "fallback":
            mark += " · fallback"
        return mark
    for k in ids:
        kind = next((c[k]["kind"] for c in cols if k in c), "")
        rows.append(f"| {k} | {kind} | " + " | ".join(cell(c.get(k)) for c in cols) + " |")
    scores = [g(phone, "apple", "suite", "score"), g(phone, "mlx", "suite", "score"), g(mac, "apple", "suite", "score"), g(mac, "mlx", "suite", "score")]
    rows.append("| **score** | | " + " | ".join(f"**{s}/12**" if s is not None else DASH for s in scores) + " |")
    if scores[0] is not None and scores[1] is not None:
        d = scores[1] - scores[0]
        rows += ["", f"**Reading:** on the phone Qwen3.5 4B scores {scores[1]}/12 against Apple's {scores[0]}/12 "
                     f"({'+' if d >= 0 else ''}{d}). T's rule: the optional model is chosen by this suite, not by size."]
    return rows


def header(phone, mac):
    rows = ["# Sweep 2b · 3.3 — iPhone spike answers (design.md §15)", ""]
    for side, r in [("Phone", phone), ("Mac", mac)]:
        if r:
            m = r.get("meta", {})
            rows.append(f"- {side}: {g(m, 'device', 'machine')} ({g(m, 'device', 'hwModel', default='?')}) · {g(m, 'device', 'os')} · {g(m, 'device', 'physicalMemoryGB', default=0):.1f} GB · "
                        f"phases {', '.join(m.get('phases', []))} · {m.get('totalS', '?')} s{' · **DRY RUN (no model was called)**' if m.get('dryRun') else ''}")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phone")
    ap.add_argument("--mac")
    ap.add_argument("--out")
    a = ap.parse_args()
    phone, mac = load(a.phone), load(a.mac)
    if not phone and not mac:
        sys.exit("give --phone and/or --mac")
    lines = header(phone, mac) + [""] + q1(phone, mac) + q2(phone, mac) + q3(phone, mac) + q4(phone, mac) + q5(phone, mac) + q6(phone, mac)
    text = "\n".join(lines) + "\n"
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(text)
    print(text)


if __name__ == "__main__":
    main()
