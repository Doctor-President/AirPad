#!/usr/bin/env python3
"""live-36 (2) — dump what one question's turns did, from a -WebTrace file, as readable text:
the rewritten queries; every result as returned (title, host, date, length); every source the rerank got (provider +
Wikipedia, with length); each passage's score and whether it was kept (floor / budget); the exact text the model
received; the answer.        trace_dump.py <webtrace.jsonl> "<question>" [...]   (each question's turns in order)
"""
import json, re, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
turns, cur = [], None
for r in rows:
    if r["kind"] == "turn": cur = [r]; turns.append(cur)
    elif cur is not None: cur.append(r)
host = lambda u: re.sub(r"^https?://(www\.)?", "", u or "").split("/")[0]
for q in sys.argv[2:]:
    for t in [t for t in turns if t[0]["question"].strip() == q.strip()][:1]:
        print("=" * 100); print("QUESTION:", q)
        for r in t:
            k = r["kind"]
            if k == "plan": print("plan:", {x: r.get(x) for x in ("prefetch", "followUp", "asksCurrentState", "path") if x in r})
            elif k == "query": print(f"query ({r.get('how')}, {r.get('rewriteMs')} ms): {r['query']!r} · Wikipedia: {r.get('wikiQuery')!r}")
            elif k == "provider": print(f"provider: {r['name']} freshness={r.get('freshness')}")
            elif k == "tool":
                print(f"results returned ({len(r.get('links', []))}):")
                for l in r.get("links", []):
                    print(f"   - {host(l['url'])} | {l.get('published') or 'no date'} | {len(l.get('snippet', ''))} ch | {l.get('title', '')[:90]}")
            elif k == "rerank":
                print(f"sources the rerank got ({len(r.get('sources', []))}), floor {float(r['floor']):.2f}, kept {r['kept']}:")
                for i, s in enumerate(r.get("sources", [])):
                    ps = [p for p in r["passages"] if p["url"] == s["url"]]
                    kept = [p for p in ps if p["kept"]]; above = [p for p in ps if p["score"] >= float(r["floor"])]
                    print(f"   [{i}] {'WIKI ' if s.get('wikipedia') else ''}{host(s['url'])} | {s.get('published') or 'no date'} | {s['chars']} ch | "
                          f"{len(ps)} passages, {len(above)} ≥ floor, {len(kept)} kept | {s['title'][:70]}")
            elif k == "applePrompt":
                print(f"APPLE: contextSize={r.get('contextSize')} tokenCount={r.get('tokenCount')} chars={r.get('chars')}")
                print("--- the prompt the model received ---"); print(r.get("prompt", "")); print("--- end ---")
            elif k == "step":
                msgs = r.get("messages", [])
                print(f"HOST step {r.get('step')}: model {r.get('model')}, {sum(len(m.get('content', '')) for m in msgs)} ch in {len(msgs)} messages")
                for m in msgs:
                    if m.get("role") != "system" or "[1]" in m.get("content", ""):
                        print(f"--- {m.get('role')} message the model received ---"); print(m.get("content", "")); print("--- end ---")
            elif k == "answer":
                print("ANSWER:"); print(r.get("text", "")); print("line:", r.get("line") or "-", "· cited:", r.get("cited"))
