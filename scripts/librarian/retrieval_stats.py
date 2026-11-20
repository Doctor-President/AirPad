#!/usr/bin/env python3
"""Sweep 2a — what the retrieval step did across a benchmark run, from the recorder's rows (no answers needed).

  retrieval_stats.py <cases.json> <results.json> [...more pairs]

Per run: the route decision by question type; whether a supporting entry was scored / sent and at what rank; how well
each candidate signal (similarity score, keyword overlap, rare-word overlap) separates supporting entries from the rest
(per candidate) and questions-with-evidence from questions-without (per question, AUROC).
"""
import json, sys
from collections import Counter, defaultdict
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import bench

NO_EVIDENCE = {"gk-irrelevant", "gk-irrelevant-overlap", "no-match", "no-match-named", "news-library"}


def auroc(pos, neg):
    if not pos or not neg:
        return None
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def run(cases_path, results_path):
    doc, cases = bench.load_cases(cases_path)
    res = json.load(open(results_path))
    keys = bench.key_maps(res)
    print(f"\n=== {doc['library']} library ({res['nodes']} entries), {len(res['rows'])} turns")
    decisions = defaultdict(Counter)
    cand = []      # (relevant, score, lex, rare, kind)
    qfeat = []     # (has_evidence, top_passage, top_card, max_rare, max_lex, n_sent)
    support_rank = []
    sent_noise = Counter()
    for r in res["rows"]:
        c = cases[r["id"]]
        if r["mode"] != "library":
            continue
        rec = r["record"]
        t = c["type"]
        decisions[t][rec.get("decision", "?")] += 1
        supports = set(c.get("supports") or [])
        ps, cs = rec.get("passages", []), rec.get("cards", [])
        if not ps and not cs:
            continue
        for p in ps:
            cand.append((keys.get(p["node"]) in supports, p["score"], p.get("lexHits", 0), p.get("rareHits", 0), "passage"))
        for x in cs:
            cand.append((keys.get(x["node"]) in supports, x["score"], x.get("lexHits", 0), x.get("rareHits", 0), "card"))
        has = t not in NO_EVIDENCE and bool(supports)
        if t in NO_EVIDENCE or has:
            qfeat.append((has, max((p["score"] for p in ps), default=0), max((x["score"] for x in cs), default=0),
                          max([p.get("rareHits", 0) for p in ps] + [x.get("rareHits", 0) for x in cs], default=0),
                          max([p.get("lexHits", 0) for p in ps] + [x.get("lexHits", 0) for x in cs], default=0),
                          len(rec.get("sent", [])), r["id"]))
        if has:
            pr = next((i + 1 for i, p in enumerate(ps) if keys.get(p["node"]) in supports), None)
            cr = next((i + 1 for i, x in enumerate(cs) if keys.get(x["node"]) in supports), None)
            sent = any(keys.get(s["node"]) in supports for s in rec.get("sent", []))
            read = any(keys.get(s["node"]) in supports and s["kind"].startswith("read") for s in rec.get("sent", []))
            support_rank.append((r["id"], pr, cr, sent, read, rec.get("decision")))
        n_noise = sum(1 for s in rec.get("sent", []) if keys.get(s["node"]) not in supports)
        sent_noise[t] += n_noise
    print("decision by type:")
    for t, cnt in sorted(decisions.items()):
        print(f"  {t:26} " + ", ".join(f"{k} {v}" for k, v in cnt.most_common()))
    ne = [q for q in qfeat if not q[0]]
    ev = [q for q in qfeat if q[0]]
    print(f"questions with NO evidence in the library: {len(ne)}; took the empty path: {sum(1 for q in ne if q[5] == 0)}; "
          f"items sent to the model on those: median {sorted(q[5] for q in ne)[len(ne) // 2] if ne else '-'}")
    print(f"questions WITH evidence: {len(ev)}; a supporting entry was sent: {sum(1 for s in support_rank if s[3])}/{len(support_rank)}; "
          f"read in full: {sum(1 for s in support_rank if s[4])}; best supporting passage ranked first: {sum(1 for s in support_rank if s[1] == 1)}; "
          f"not among the 12 passages: {sum(1 for s in support_rank if s[1] is None)}; best supporting summary ranked first: {sum(1 for s in support_rank if s[2] == 1)}")
    miss = [s for s in support_rank if not s[3]]
    if miss:
        print("  supporting entry NOT sent: " + ", ".join(f"{s[0]}(passage rank {s[1]}, summary rank {s[2]}, {s[5]})" for s in miss))
    print("per-question separation, evidence vs none (AUROC; 1.0 = perfect, 0.5 = coin):")
    for name, i in (("top passage score", 1), ("top summary score", 2), ("most rare question words in a candidate", 3), ("most question words in a candidate", 4)):
        a = auroc([q[i] for q in ev], [q[i] for q in ne])
        print(f"  {name:42} {a:.2f}" if a is not None else f"  {name:42} -")
    if ne and ev:
        print("  top passage score: evidence min/median/max %.2f/%.2f/%.2f | none min/median/max %.2f/%.2f/%.2f" % (
            min(q[1] for q in ev), sorted(q[1] for q in ev)[len(ev) // 2], max(q[1] for q in ev),
            min(q[1] for q in ne), sorted(q[1] for q in ne)[len(ne) // 2], max(q[1] for q in ne)))
    rel = [c for c in cand if c[0]]
    irr = [c for c in cand if not c[0]]
    print(f"per-candidate: {len(rel)} supporting, {len(irr)} not. Rules tried (kept supporting / kept non-supporting):")
    rules = [("score >= 0.60 (today's passage bar)", lambda c: c[1] >= 0.60), ("score >= 0.52 (today's summary bar)", lambda c: c[1] >= 0.52),
             ("score >= 0.65", lambda c: c[1] >= 0.65), ("score >= 0.70", lambda c: c[1] >= 0.70),
             ("a rare question word present", lambda c: c[3] >= 1), ("two question words present", lambda c: c[2] >= 2),
             ("score >= 0.60 AND a rare word", lambda c: c[1] >= 0.60 and c[3] >= 1),
             ("score >= 0.55 AND (a rare word OR two words)", lambda c: c[1] >= 0.55 and (c[3] >= 1 or c[2] >= 2)),
             ("a rare word OR score >= 0.70", lambda c: c[3] >= 1 or c[1] >= 0.70)]
    for name, f in rules:
        kr, ki = sum(1 for c in rel if f(c)), sum(1 for c in irr if f(c))
        print(f"  {name:46} {kr:>3}/{len(rel)} ({100 * kr // max(1, len(rel))}%)   {ki:>4}/{len(irr)} ({100 * ki // max(1, len(irr))}%)")
    return qfeat


if __name__ == "__main__":
    a = sys.argv[1:]
    for i in range(0, len(a), 2):
        run(a[i], a[i + 1])
