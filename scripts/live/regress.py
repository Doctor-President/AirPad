#!/usr/bin/env python3
"""live-36 (3) — grade one tier's run of the fixed regression set (scripts/live/set-regression.json) from the app's
-WebTrace file. Two grades per answer:
  RETRIEVAL — was every `gold` group in what the model RECEIVED (the Host step's messages / Apple's prompt)? When not,
              where it was lost: never fetched · fetched but split / no passage · passage below the floor ·
              above the floor but cut (top-k / per-source / character budget) · kept but not in the prompt.
  ANSWER    — relaxed: every `any` group hit (the main answer right); strict: relaxed + no `stale` claim + the exact
              `rows` + no thinking aloud + the `official` host among the sources + no off-topic source.
A case with `review` gets its deterministic grade plus "review" (a reviewer's verdict in reviews.json overrides).
    regress.py <set.json> <webtrace.jsonl> <out_dir> <tier label> [reviews.json]
Writes grades.json + table.md (per question) + summary.md (category × retrieval / strict / relaxed).
"""
import json, re, sys, os, datetime
SET, TRACE, OUT, TIER = sys.argv[1:5]
REVIEWS = json.load(open(sys.argv[5])) if len(sys.argv) > 5 and os.path.exists(sys.argv[5]) else {}
cases = json.load(open(SET))["chats"]
only = [x for x in os.environ.get("LIVE_ONLY", "").split(",") if x]
if only: cases = [c for c in cases if c["id"] in only]
rows = [json.loads(l) for l in open(TRACE)] if os.path.exists(TRACE) else []
THINK = re.compile(r"\b(wait|hmm+|actually,|let me (check|think|re-?check|verify|recount)|on second thought|re-?checking|double-check)\b|\(wait", re.I)

turns, cur = [], None
for r in rows:
    # a second "turn" row for the same question before any answer is the same turn (two trace points mark it)
    if r["kind"] == "turn" and not (cur and cur["q"] == r["question"] and not any(x["kind"] == "answer" for x in cur["rows"])):
        cur = {"q": r["question"], "rows": [r]}; turns.append(cur)
    elif cur: cur["rows"].append(r)

def take(q, used):
    q = q[4:] if q.startswith("LIB:") else q
    for i, t in enumerate(turns):
        if i not in used and t["q"].strip() == q.strip(): used.add(i); return t
    return None

def low(s): return re.sub(r"[*_`]", "", (s or "").lower()).replace("’", "'").replace(" ", " ")
def hit(text, k, rx): return bool(re.search(k, text)) if rx else k in text
def groups_ok(text, groups, rx=False): return all(any(hit(text, k, rx) for k in g) for g in groups)
def missing(text, groups, rx=False): return [g for g in groups if not any(hit(text, k, rx) for k in g)]

def table_rows(ans):
    t = [l.strip() for l in ans.splitlines() if l.strip().startswith("|")]
    data = [l for l in t if not re.match(r"^\|[\s:|-]+\|?$", l)]
    return max(0, len(data) - 1) if t else None   # minus the header
def list_items(ans):
    return len([l for l in ans.splitlines() if re.match(r"^\s*(\d+[.)]|[-*•])\s+\S", l)])

def received(t):
    """What the model got: the first model step's messages (Host / server) or Apple's prompt."""
    step = next((r for r in t["rows"] if r["kind"] == "step"), None)
    if step: return " \n".join(m.get("content", "") for m in step.get("messages", [])), "host"
    ap = next((r for r in t["rows"] if r["kind"] == "applePrompt"), None)
    if ap: return "\n".join([ap.get("instructions", "")] + ap.get("history", []) + [ap.get("prompt", "")]), "apple"
    return "", "none"

def loss_stage(g, t, rx):
    """For one gold group missing from what the model got: the first stage it is absent from, going backwards."""
    rr = next((r for r in t["rows"] if r["kind"] == "rerank"), None)
    tool = [r for r in t["rows"] if r["kind"] == "tool"]
    fetched = " ".join(low(l.get("title", "") + " " + l.get("snippet", "")) for r in tool for l in r.get("links", []))
    fetched += " " + " ".join(low(s.get("title", "") + " " + s.get("text", "")) for s in (rr or {}).get("sources", []))
    if not tool and not rr: return "not searched"
    if not any(hit(fetched, k, rx) for k in g): return "never fetched"
    ps = (rr or {}).get("passages", [])
    floor = float((rr or {}).get("floor", 0.6))
    with_fact = [p for p in ps if any(hit(low(p.get("text", "")), k, rx) for k in g)]
    if not with_fact: return "fetched, in no passage (split / cut from the page)"
    if not any(p["score"] >= floor for p in with_fact): return f"below the floor (best {max(p['score'] for p in with_fact):.2f})"
    if not any(p.get("kept") for p in with_fact): return "above the floor but cut (top-k / per-source / budget)"
    return "kept but not in the prompt"

def grade(c, ts):
    t = ts[-1]
    rx = c.get("regex", False)
    out = {"id": c["id"], "cat": c["cat"], "q": c["turns"][-1], "rubric": c["rubric"], "tFailure": c.get("tFailure", False)}
    if t is None and not c.get("nosearch"):
        out.update(retrieval=None, relaxed=False, strict=False, note="turn not in trace", answer=""); return out
    trows = t["rows"] if t else []
    ans_row = next((r for r in trows if r["kind"] == "answer"), None)
    ans = (ans_row or {}).get("text", "")
    a = low(ans)
    searched = any(r["kind"] == "tool" for r in trows)
    if c.get("nosearch"):
        out.update(retrieval=None, relaxed=not searched, strict=not searched, searched=searched, answer=ans[:600],
                   note="searched!" if searched else "no search"); return out
    ctx, path = received(t)
    lctx = low(ctx)
    gold = c.get("gold", [] if c.get("abstain") else c["any"])
    # retrieval
    if c.get("recentDays"):
        rr = next((r for r in trows if r["kind"] == "rerank"), None)
        now = datetime.datetime.now(datetime.timezone.utc)
        dated = []
        for l in (rr or {}).get("links", []):
            try: dated.append((now - datetime.datetime.fromisoformat(l["published"].replace("Z", "+00:00"))).days)
            except Exception: pass
        recent = [d for d in dated if d <= c["recentDays"]]
        out["retrieval"] = bool(recent); out["retrievalNote"] = f"{len(recent)} of {len(dated)} dated passed sources ≤ {c['recentDays']} d"
    elif gold and not searched:
        out["retrieval"] = None; out["retrievalNote"] = "not searched (answered from memory)"
    elif gold:
        miss = missing(lctx, gold, rx)
        out["retrieval"] = not miss
        out["lost"] = {" / ".join(g): loss_stage(g, t, rx) for g in miss}
    else:
        out["retrieval"] = None
    # answer
    relaxed = bool(ans) and groups_ok(a, c["any"], rx) if c["any"] else bool(ans)
    stale = [p for p in c.get("stale", []) if re.search(p, a)]
    think = sorted({m.group(0) for m in THINK.finditer(ans)})
    probs = []
    if stale: probs.append("stale: " + "; ".join(stale))
    if think: probs.append("thinking aloud: " + ", ".join(think))
    if c.get("strictAny"):
        miss_s = missing(a, c["strictAny"], rx)
        if miss_s: probs.append("missing: " + ", ".join(g[0] for g in miss_s))
    if c.get("rows"):
        n = c["rows"]["n"]
        got = table_rows(ans) if c["rows"].get("kind") == "table" or table_rows(ans) else list_items(ans)
        out["rows"] = got
        if got != n: probs.append(f"rows {got} ≠ {n}")
    rr = next((r for r in trows if r["kind"] == "rerank"), None)
    hosts = []
    for l in (rr or {}).get("links", []):
        h = re.sub(r"^https?://(www\.)?", "", l.get("url", "")).split("/")[0]
        if h and h not in hosts: hosts.append(h)
    out["sources"] = hosts
    if c.get("official") and not any(c["official"] in h for h in hosts): probs.append(f"no {c['official']} source")
    if c.get("offTopic"):
        off = [l.get("url", "") for l in (rr or {}).get("links", []) if re.search(c["offTopic"], low(l.get("title", "")))]
        if off: probs.append("off-topic source: " + ", ".join(off))
    if relaxed and stale: relaxed = not any(re.search(p, a) for p in c.get("stale", []) if not c.get("abstain"))   # a stale MAIN claim
    out.update(relaxed=relaxed, strict=relaxed and not probs, problems=probs, answer=ans[:2500], path=path,
               query=next((r.get("query") for r in trows if r["kind"] == "query"), ""),
               line="unconfirmed: true" in (ans_row or {}).get("line", ""), contextChars=len(ctx),
               searched=searched)
    ap = next((r for r in trows if r["kind"] == "applePrompt"), None)
    if ap: out["apple"] = {"contextSize": ap.get("contextSize"), "tokenCount": ap.get("tokenCount")}
    if c.get("review"):
        out["review"] = c["review"]
        rv = REVIEWS.get(c["id"])
        if rv: out.update(strict=rv.get("strict", out["strict"]), relaxed=rv.get("relaxed", out["relaxed"]), reviewed=rv.get("why", "reviewed"))
    return out

res = []
for c in cases:
    used = set()
    ts = [take(q, used) for q in c["turns"]]
    res.append(grade(c, ts))
os.makedirs(OUT, exist_ok=True)
json.dump(res, open(os.path.join(OUT, "grades.json"), "w"), indent=1, ensure_ascii=False)
yn = lambda v: "-" if v is None else ("y" if v else "n")
L = [f"# {TIER} — {len(res)} questions", "", "| id | cat | retrieval | strict | relaxed | lost / problems | query | sources |", "|---|---|---|---|---|---|---|---|"]
for g in res:
    why = "; ".join([f"{k}: {v}" for k, v in (g.get("lost") or {}).items()] + g.get("problems", []) + ([g["retrievalNote"]] if g.get("retrievalNote") else [])
                    + ([f"REVIEW: {g['review']}" + (f" → {g['reviewed']}" if g.get("reviewed") else "")] if g.get("review") else []) + ([g["note"]] if g.get("note") else []))
    L.append(f"| {g['id']}{' ★' if g.get('tFailure') else ''} | {g['cat']} | {yn(g.get('retrieval'))} | {yn(g['strict'])} | {yn(g['relaxed'])} | {why.replace('|', '/')} | {(g.get('query') or '').replace('|', '/')} | {', '.join(g.get('sources', []))} |")
open(os.path.join(OUT, "table.md"), "w").write("\n".join(L) + "\n")
cats = []
for g in res:
    if g["cat"] not in cats: cats.append(g["cat"])
S = [f"# {TIER} — summary", "", "| category | n | retrieval recall | strict | relaxed |", "|---|---|---|---|---|"]
def frac(xs): xs = [x for x in xs if x is not None]; return f"{sum(xs)}/{len(xs)}" if xs else "-"
for k in cats + ["ALL"]:
    gs = [g for g in res if k == "ALL" or g["cat"] == k]
    S.append(f"| {k} | {len(gs)} | {frac([g.get('retrieval') for g in gs])} | {frac([g['strict'] for g in gs])} | {frac([g['relaxed'] for g in gs])} |")
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(S) + "\n")
print("\n".join(S))
