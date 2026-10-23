#!/usr/bin/env python3
"""live-37 (4) — a smoke answer run before vs after: every case's retrieval / strict / relaxed, and each case that got WORSE.
    smoke_answers.py <before_dir> <after_dir>
"""
import json, sys
b, a = ({g["id"]: g for g in json.load(open(d + "/grades.json"))} for d in sys.argv[1:3])
yn = lambda v: "–" if v is None else ("y" if v else "n")
f = lambda g, k: [x.get(k) for x in g.values() if x.get(k) is not None]
for name, g in (("before", b), ("after", a)):
    print(f"- {name}: retrieval {sum(f(g,'retrieval'))}/{len(f(g,'retrieval'))} · strict {sum(f(g,'strict'))}/{len(f(g,'strict'))} · relaxed {sum(f(g,'relaxed'))}/{len(f(g,'relaxed'))}")
print("\n| case | before R·S·L | after R·S·L |\n|---|---|---|")
for i in b:
    print(f"| {i}{' ★' if b[i].get('tFailure') else ''} | " + " | ".join(f"{yn(g[i].get('retrieval'))} {yn(g[i].get('strict'))} {yn(g[i].get('relaxed'))}" for g in (b, a)) + " |")
worse = [i for i in b if any(b[i].get(k) is True and a[i].get(k) is False for k in ("retrieval", "strict", "relaxed"))]
print("\n**Worse:** " + ("none" if not worse else ""))
for i in worse:
    print(f"- {i}: " + ", ".join(k for k in ("retrieval", "strict", "relaxed") if b[i].get(k) is True and a[i].get(k) is False)
          + f" — after: {'; '.join([f'{k}: {v}' for k, v in (a[i].get('lost') or {}).items()] + a[i].get('problems', []))} · query {a[i].get('query')!r}")
