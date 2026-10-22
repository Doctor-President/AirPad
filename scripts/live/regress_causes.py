#!/usr/bin/env python3
"""live-36 — each strict failure's cause, from a tier's grades.json + webtrace.jsonl + the set:
  QUERY      the rewrite added a name / number that is nowhere in the conversation (user turns and earlier answers),
             and retrieval failed — e.g. "Price of iPhone 15" for "What's the price of an iPhone?"
  CUT        the gold was fetched and above the similarity floor but cut by top-k / per-source / the character budget
  FLOOR      the gold was fetched but its passage scored below the floor
  FETCH      the provider / Wikipedia never returned the gold (with the query as the user meant it)
  MODEL      the gold was in what the model received (MODEL+QUERY: and the rewrite had added a stale name the answer followed)
  N/A        not searched, or no gold to check
    regress_causes.py <set.json> <tier_dir>     → prints a table + counts
"""
import json, re, sys, os
SET, D = sys.argv[1:3]
cases = {c["id"]: c for c in json.load(open(SET))["chats"]}
grades = json.load(open(os.path.join(D, "grades.json")))
rows = [json.loads(l) for l in open(os.path.join(D, "run", "webtrace.jsonl"))]
answers, cur = {}, None
for r in rows:
    if r["kind"] == "turn": cur = r["question"]
    elif r["kind"] == "answer" and cur: answers.setdefault(cur, r.get("text", ""))
STOP = set("list of the a an and to for in on at by from with what who is are was were how many much does do did current latest new newest price prices pricing cost table last first us u.s. today 2026 president presidents".split())
def words(s): return set(w for w in re.findall(r"[a-z0-9]+", s.lower()))
def drift(c, query):
    allowed = set()
    for i, q in enumerate(c["turns"]):
        q = q[4:] if q.startswith("LIB:") else q
        allowed |= words(q) | (words(answers.get(q, "")) if i < len(c["turns"]) - 1 else set())   # earlier answers only
    added = [w for w in re.findall(r"[A-Za-z]+|\d+", query) if (w[0].isupper() or w.isdigit()) and w.lower() not in allowed and w.lower() not in STOP]
    return added
from collections import Counter
cnt = Counter(); out = []
for g in grades:
    if g["strict"]: continue
    c = cases[g["id"]]
    q = g.get("query") or ""
    add = drift(c, q) if q else []
    if g.get("retrieval") is True: cause = "MODEL+QUERY" if add else "MODEL"   # the gold arrived; a drifted query can still steer it
    elif g.get("retrieval") is None: cause = "N/A"
    elif add: cause = "QUERY"
    else:
        st = " ".join((g.get("lost") or {}).values())
        cause = "CUT" if "cut" in st else "FLOOR" if "below the floor" in st else "FETCH"
    cnt[cause] += 1
    out.append(f"| {g['id']} | {cause} | {q} | {' '.join(add) or '–'} | {'; '.join(f'{k}: {v}' for k, v in (g.get('lost') or {}).items())[:110]} | {'; '.join(g.get('problems', []))[:90]} |".replace("\n", " "))
print("| id | cause | query | added by the rewrite | lost | problems |\n|---|---|---|---|---|---|"); print("\n".join(out))
print("\n" + " · ".join(f"{k} {v}" for k, v in cnt.most_common()))
