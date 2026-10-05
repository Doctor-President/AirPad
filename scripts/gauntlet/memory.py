#!/usr/bin/env python3
"""CH-A (T ruling 3) — resident memory vs context window, per store pass: `memory.py <pass_dir>...`

One row per pass: the num_ctx the app sent (turn tap), what Ollama actually served (/api/ps context_length),
the KV cache type Ollama loaded with (its own load log, relayed in host.log), the max resident size
(/api/ps size_vram), the graders' pass rate, and how many reads went PARTIAL / were truncated."""
import json, os, re, sys, glob
sys.path.insert(0, os.path.dirname(__file__))
import gauntlet as G

print("| pass | model | num_ctx sent | ctx served | KV cache | resident | graders clean | read in full / PARTIAL | truncated | max prompt_eval |")
print("|---|---|---|---|---|---|---|---|---|---|")
for P in sys.argv[1:]:
    v = G.load_json(os.path.join(P, "versions.json"), {})
    g = G.load_json(os.path.join(P, "grades.json"), {})
    turns = [G.load_json(p) for p in sorted(glob.glob(os.path.join(P, "turn-*.json")))]
    turns = [t for t in turns if t]
    sent = sorted({t.get("numCtx") for t in turns if t.get("numCtx")})
    model = v.get("model", "")
    size, ctx = G.resident_sizes(os.path.join(P, "ps.log")).get(model, (0, 0))
    hl = open(os.path.join(P, "host.log"), errors="replace").read() if os.path.exists(os.path.join(P, "host.log")) else ""
    kv = sorted({m or "f16 (default)" for m in re.findall(r"KvCacheType:(\S*)", hl)}) or ["(no load in this pass)"]
    host = G.parse_host_log(os.path.join(P, "host.log"))
    trunc = sum(1 for h in host.values() if h.get("truncated"))
    pe = max((h.get("prompt_eval", 0) for h in host.values()), default=0)
    clean = sum(1 for r in g.values() if r["status"] not in ("FAIL", "INVALID"))
    full = sum(1 for t in turns if "in full" in (t.get("receipt") or ""))
    partial = sum(1 for t in turns if t.get("isPartial"))
    print(f"| {os.path.basename(os.path.normpath(P))} | {model} | {','.join(map(str, sent)) or '—'} | {ctx or '—'} | {', '.join(kv)} | "
          f"{size / 1e9:.2f} GB | {clean}/{len(g)} | {full} / {partial} | {trunc} | {pe} |")
