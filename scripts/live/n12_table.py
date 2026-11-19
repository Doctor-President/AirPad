#!/usr/bin/env python3
"""N12 — one row per question from a `-WebTrace` file: the path, the sources the model saw (Wikipedia vs web), the
search's freshness window, and the start of the answer (or the app's notice). REF rows are graded by a gold word;
TS rows: on-topic = a news answer from web sources, or the plain "can't look up today's news" line.
  python3 scripts/live/n12_table.py scripts/live/set-n12.json <webtrace.jsonl> [label]"""
import json, re, sys

GOLD = {"REF-01": r"austen", "REF-02": r"canberra", "REF-03": r"8,?8[45]\d|29,0\d\d", "REF-04": r"1989",
        "REF-05": r"light|sun", "REF-06": r"leonardo|da vinci", "REF-07": r"1066|william", "REF-08": r"\btwo\b|\b2\b|phobos",
        "REF-09": r"mathematic|analytical engine|babbage", "REF-10": r"299,?792|186,?000|300,?000"}
NOTICE = re.compile(r"can't look up today's news", re.I)

def rows(path):
    turns, cur = [], None
    for line in open(path):
        try: r = json.loads(line)
        except Exception: continue
        if r.get("kind") == "turn":
            cur = {"q": r.get("question", ""), "path": "", "wiki": 0, "web": 0, "fresh": "", "answer": "", "caption": ""}
            turns.append(cur); continue
        if cur is None: continue
        k = r.get("kind")
        if k == "query" and r.get("path"): cur["path"] = r["path"]
        if k == "plan" and r.get("path"): cur["path"] = r["path"]
        if k == "tool" and r.get("name") == "web_search":
            cur["fresh"] = str((r.get("args") or {}).get("freshness", "")) or cur["fresh"]
        if k == "rerank":
            cur["wikiFetched"] = cur.get("wikiFetched", 0) + sum(1 for s in r.get("sources", []) if s.get("wikipedia"))
            for l in r.get("links", []):
                if l.get("title", "").startswith("Wikipedia: "): cur["wiki"] += 1
                else: cur["web"] += 1
        if k == "evidence" and not cur["path"]: cur["path"] = "retrieval"
        if k == "answer":
            cur["answer"] = (r.get("text") or "").replace("\n", " ")
            cur["caption"] = r.get("caption", "")
    return turns

def main():
    cases = json.load(open(sys.argv[1]))["chats"]
    label = sys.argv[3] if len(sys.argv) > 3 else ""
    by_q = {}
    for t in rows(sys.argv[2]): by_q[t["q"]] = t   # the last run of a question wins
    print(f"| id | path | wiki fetched/kept | web kept | fresh | on-topic | answer (start) |  {label}")
    print("|---|---|---|---|---|---|---|")
    for c in cases:
        q = c["turns"][0]; t = by_q.get(q)
        if not t: print(f"| {c['id']} | (no turn) | | | | | |"); continue
        a = t["answer"]
        if c["id"] in GOLD: ok = "yes" if re.search(GOLD[c["id"]], a, re.I) else ("—" if not a else "NO")
        else: ok = "notice" if NOTICE.search(a) else ("WIKI" if t["wiki"] or t.get("wikiFetched") else "?")
        wiki = f"{t.get('wikiFetched', 0)}/{t['wiki']}"
        print(f"| {c['id']} | {t['path'] or '-'} | {wiki} | {t['web']} | {t['fresh'] or '-'} | {ok} | {a[:110]} |")

if __name__ == "__main__":
    main()
