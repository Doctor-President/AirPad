#!/usr/bin/env python3
"""live-32 (3) — grade a live run from the app's -WebTrace file against a set (scripts/live/set-*.json).

Per graded turn: NAMES the current holder (every `any` group has a hit), CITES a source that says so (a cited result
whose snippet or read text names it), no STALE claim (`stale` regexes), no THINKING aloud, and the time per stage.
Writes grades.json + table.md into <out_dir>.   usage: grade.py <set.json> <webtrace.jsonl> <out_dir>
"""
import json, re, sys, os
SET, TRACE, OUT = sys.argv[1:4]
cases = json.load(open(SET))["chats"]
only = [x for x in os.environ.get("LIVE_ONLY", "").split(",") if x]
if only: cases = [c for c in cases if c["id"] in only]
rows = [json.loads(l) for l in open(TRACE)] if os.path.exists(TRACE) else []
THINK = re.compile(r"\b(wait|hmm+|actually,|let me (check|think|re-?check|verify|recount)|on second thought|i think i|re-?checking|thinking process|double-check)\b|\(wait", re.I)

# split the trace into turns (a "turn" row starts one); match each to a set turn by its question text
turns, cur = [], None
for r in rows:
    if r["kind"] == "turn": cur = {"q": r["question"], "rows": [r]}; turns.append(cur)
    elif cur: cur["rows"].append(r)

def turn_for(q, used):
    for i, t in enumerate(turns):
        if i not in used and t["q"].strip() == q.strip(): used.add(i); return t
    return None

def norm(u): return re.sub(r"^https?://(www\.)?", "", u or "").rstrip("/").lower()

def grade_turn(c, t):
    ans = next((r for r in t["rows"] if r["kind"] == "answer"), None) if t else None
    text = (ans or {}).get("text", "")
    low = re.sub(r"[*_`]", "", text.lower())   # **Joe Biden** is still a stale claim
    groups = c["any"]
    names = bool(text) and all(any(k in low for k in g) for g in groups)
    stale = [p for p in c.get("stale", []) if re.search(p, low)]
    think = sorted({m.group(0) for m in THINK.finditer(text)})
    # what each source said: search results' snippets, read pages' text
    said = {}
    for r in (t["rows"] if t else []):
        if r["kind"] == "tool":
            for l in r.get("links", []):
                u = norm(l["url"]); said[u] = said.get(u, "") + " " + (l.get("title", "") + " " + l.get("snippet", "")).lower()
            if r.get("name") in ("fetch_url", "wikipedia") or r.get("url"):
                u = norm(r.get("args", {}).get("url", "") or r.get("url", ""))
                if u: said[u] = said.get(u, "") + " " + r.get("text", "").lower()
    cited = [norm(u) for u in (ans or {}).get("cited", [])]
    supports = [u for u in cited if any(any(k in said.get(u, "") for k in g) for g in groups)]
    passed_any = [u for u, s in said.items() if any(any(k in s for k in g) for g in groups)]
    # stages
    st = {"total_s": round(((ans or t["rows"][-1] if t else {}) or {}).get("ms", 0) / 1000, 1) if t else None}
    if t:
        q = next((r for r in t["rows"] if r["kind"] == "query"), None)
        st["rewrite_s"] = round(q["ms"] / 1000, 1) if q else 0
        st["tools"] = [f'{r["name"]} {round((r["ms"] - r.get("startMs", r["ms"])) / 1000, 1)}s' for r in t["rows"] if r["kind"] == "tool"]
        st["steps"] = [f'{round((r["ms"] - r["startMs"]) / 1000, 1)}s (first token {round((r["firstContentMs"] - r["startMs"]) / 1000, 1) if r["firstContentMs"] >= 0 else "-"}s, reasoning {r["reasoningChars"]} ch)' for r in t["rows"] if r["kind"] == "step"]
        st["model"] = next((r.get("model") for r in t["rows"] if r["kind"] == "step"), "")
        st["query"] = q["query"] if q else ""
        st["prefetch"] = next((r.get("prefetch") for r in t["rows"] if r["kind"] == "plan"), "")
    ok = names and bool(supports) and not stale and not think
    return {"answered": bool(text), "names": names, "cites": bool(supports), "passedAny": len(passed_any), "stale": stale,
            "thinking": think, "pass": ok, "stages": st, "answer": text[:1500], "cited": cited}

out = []
for c in cases:
    used = set()
    ts = [turn_for(q, used) for q in c["turns"]]
    graded = list(enumerate(ts)) if c.get("anyEach") else [(len(ts) - 1, ts[-1])]
    for i, t in graded:
        g = grade_turn(c, t); g["id"] = c["id"] + (f".{i+1}" if len(c["turns"]) > 1 else ""); g["q"] = c["turns"][i]
        if t is None: g["note"] = "turn not in trace"
        out.append(g)
json.dump(out, open(os.path.join(OUT, "grades.json"), "w"), indent=1, ensure_ascii=False)
lines = ["| case | pass | names | cites | stale | thinking | total | query | stages |", "|---|---|---|---|---|---|---|---|---|"]
for g in out:
    s = g["stages"]
    lines.append(f'| {g["id"]} | {"PASS" if g["pass"] else "FAIL"} | {"y" if g["names"] else "n"} | {"y" if g["cites"] else "n"} ({g["passedAny"]} sources name it) | {"; ".join(g["stale"]) or "-"} | {", ".join(g["thinking"]) or "-"} | {s.get("total_s")} s | {s.get("query","")} | rewrite {s.get("rewrite_s")} s · {", ".join(s.get("tools", []))} · steps {"; ".join(s.get("steps", []))} |')
lines.append(f'\n**{sum(g["pass"] for g in out)}/{len(out)} pass** · names {sum(g["names"] for g in out)} · cites {sum(g["cites"] for g in out)} · stale {sum(bool(g["stale"]) for g in out)} · thinking {sum(bool(g["thinking"]) for g in out)}')
open(os.path.join(OUT, "table.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
