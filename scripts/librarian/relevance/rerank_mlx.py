#!/usr/bin/env python3
"""Sweep 2b · 3.2 — the reranker arm: Qwen3-Reranker-0.6B in-process with MLX (no server, no port).

  rerank_mlx.py download                      the publisher's weights into HF_HOME (build/sweep2b/relevance/hf)
  rerank_mlx.py convert                       a 4-bit MLX copy (mlx_lm.convert -q) beside it
  rerank_mlx.py check                         C-d part 1: `yes` / `no` are single tokens; the prompt matches the card
  rerank_mlx.py smoke [--pairs N]             <= 20 synthetic pairs (bench planted notes vs Sample passages)
  rerank_mlx.py verify --lib L                no model: the library opened here has the signals' passages, entries
                                              and questions (same IDs, same order), or exit 2 with the counts
  rerank_mlx.py score --lib L [--precision bf16|q4] [--variants v0,v1,v2,v3] [--budget-min M]
  rerank_mlx.py time  --lib L [--pool 12,30] [--variants v0] [--questions N] [--all-wordings]
                                              ms per question at each pool size (warmed up, alone), every timed
                                              question listed by ID, peak memory (MLX + max RSS)

Library: the nodes dir given on the command line (--sample-nodes …), else the one the signals recorded
(signals-<lib>.json meta.nodes_dir), else the default. Whatever is opened must match the signals exactly (`verify`
runs first inside `score` and `time`): sweep 2b's night scored 0 of 7,002 Sample pairs because the signals indexed
the seeded Sample (712 passages) and this script opened the repo's (686), then wrote an empty cache.

Score = P(yes) from the softmax over the `yes` / `no` logits at the last position. Pairs are cached on disk by
(model, variant, question ID, block ID) — never by text — in OUT/rerank-cache/<lib>.jsonl; grade.py reads the cache.
Variants: instruction (publisher default | notes-library) × document (passage | "title\\npassage").
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import OUT, BENCHMARK, REPO, refuse_forbidden_ports, say

REPO_ID = "Qwen/Qwen3-Reranker-0.6B"
MODELS = REPO / "build" / "sweep2b" / "relevance"   # the weights stay here whatever RELEVANCE_OUT says
HF_HOME = Path(os.environ.get("RELEVANCE_HF_HOME", MODELS / "hf"))
Q4_DIR = MODELS / "models" / "qwen3-reranker-0.6b-4bit"
CACHE = OUT / "rerank-cache"

PREFIX = ("<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct "
          "provided. Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n<|im_start|>user\n")
SUFFIX = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
INSTRUCTIONS = {
    "pub": "Given a web search query, retrieve relevant passages that answer the query",
    "notes": "Given a question asked of a personal notes library, judge whether the passage contains the information "
             "that answers it",
}
VARIANTS = {"v0": ("pub", "passage"), "v1": ("pub", "title"), "v2": ("notes", "passage"), "v3": ("notes", "title")}
MAX_LEN = 512


def local_snapshot():
    """The downloaded snapshot (found on disk; never a network call)."""
    snaps = sorted((HF_HOME / "hub" / ("models--" + REPO_ID.replace("/", "--")) / "snapshots").glob("*/config.json"))
    if not snaps:
        raise SystemExit(f"{REPO_ID} not downloaded (rerank_mlx.py download)")
    return snaps[-1].parent


def download():
    os.environ["HF_HOME"] = str(HF_HOME)
    from huggingface_hub import snapshot_download
    t = time.time()
    p = Path(snapshot_download(REPO_ID, cache_dir=str(HF_HOME / "hub"),
                               allow_patterns=["*.json", "*.safetensors", "*.txt", "*.md", "*.jinja", "*.model"]))
    size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    say(f"downloaded {REPO_ID} → {p} ({size / 1e9:.2f} GB, {time.time() - t:.0f} s)")
    return p


def convert():
    from mlx_lm import convert as mlx_convert
    src = local_snapshot()
    if Q4_DIR.exists():
        say(f"4-bit copy already at {Q4_DIR}")
        return Q4_DIR
    Q4_DIR.parent.mkdir(parents=True, exist_ok=True)
    mlx_convert(hf_path=str(src), mlx_path=str(Q4_DIR), quantize=True, q_bits=4)
    size = sum(f.stat().st_size for f in Q4_DIR.rglob("*") if f.is_file())
    say(f"4-bit copy → {Q4_DIR} ({size / 1e9:.2f} GB)")
    return Q4_DIR


class Reranker:
    def __init__(self, precision="bf16"):
        import mlx.core as mx
        from mlx_lm import load
        self.mx = mx
        path = local_snapshot() if precision == "bf16" else Q4_DIR
        self.model, self.tok = load(str(path))
        self.precision = precision
        self.yes = self.tok.convert_tokens_to_ids("yes")
        self.no = self.tok.convert_tokens_to_ids("no")
        self.pre = self.tok.encode(PREFIX, add_special_tokens=False)
        self.suf = self.tok.encode(SUFFIX, add_special_tokens=False)
        self.pad = self.tok.pad_token_id if self.tok.pad_token_id is not None else self.no

    def ids(self, query, doc, instruction):
        body = self.tok.encode(f"<Instruct>: {instruction}\n<Query>: {query}\n<Document>: {doc}",
                               add_special_tokens=False)
        body = body[: MAX_LEN - len(self.pre) - len(self.suf)]
        return self.pre + body + self.suf

    def _head(self, h):
        m = self.model
        if hasattr(m, "lm_head"):
            return m.lm_head(h)
        return m.model.embed_tokens.as_linear(h)

    def score_ids(self, seqs, batch=16):
        """P(yes) per token sequence. Right padding: under the causal mask a real token never sees a pad, and the
        logits are read at each sequence's own last token."""
        mx = self.mx
        out = np.zeros(len(seqs), np.float32)
        order = sorted(range(len(seqs)), key=lambda i: len(seqs[i]))
        for s in range(0, len(order), batch):
            chunk = order[s:s + batch]
            L = max(len(seqs[i]) for i in chunk)
            arr = np.full((len(chunk), L), self.pad, dtype=np.int32)
            last = np.zeros(len(chunk), dtype=np.int32)
            for r, i in enumerate(chunk):
                arr[r, : len(seqs[i])] = seqs[i]
                last[r] = len(seqs[i]) - 1
            h = self.model.model(mx.array(arr))
            hl = h[mx.arange(len(chunk)), mx.array(last)]
            logits = self._head(hl).astype(mx.float32)
            two = mx.stack([logits[:, self.no], logits[:, self.yes]], axis=1)
            p = mx.softmax(two, axis=1)[:, 1]
            mx.eval(p)
            out[chunk] = np.array(p)
        return out

    def score(self, pairs, variant="v0", batch=16):
        ins, docform = VARIANTS[variant]
        seqs = [self.ids(q, (f"{t}\n{d}" if docform == "title" else d), INSTRUCTIONS[ins]) for q, d, t in pairs]
        return self.score_ids(seqs, batch)


def check_card_and_tokens(r=None):
    """C-d part 1. Returns (ok, details)."""
    snap = local_snapshot()
    readme = (snap / "README.md").read_text(encoding="utf-8") if (snap / "README.md").is_file() else ""
    card_ok = all(s in readme for s in (
        "Judge whether the Document meets the requirements based on the Query and the Instruct provided",
        "<think>\\n\\n</think>\\n\\n", "<Instruct>: {instruction}\\n<Query>: {query}\\n<Document>: {doc}"))
    from transformers import AutoTokenizer  # tokenizer files only (no torch needed)
    tok = AutoTokenizer.from_pretrained(str(snap))
    y, n = tok.convert_tokens_to_ids("yes"), tok.convert_tokens_to_ids("no")
    single = tok.encode("yes", add_special_tokens=False) == [y] and tok.encode("no", add_special_tokens=False) == [n]
    ok = card_ok and single and y != n and y is not None and n is not None
    return ok, {"yes_id": y, "no_id": n, "single_tokens": single, "prompt_matches_model_card": card_ok}


class PoolMismatch(Exception):
    """The library opened here is not the one the signals were computed on (counts only in the message)."""


def cache_path(lib, out=None):
    return (CACHE if out is None else Path(out) / "rerank-cache") / f"{lib}.jsonl"


def load_cache(lib, out=None):
    d = {}
    p = cache_path(lib, out)
    if p.is_file():
        for line in p.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                d[(r["m"], r["v"], r["q"], r["b"])] = r["s"]
    return d


def alignment_problems(lib, meta, rows_p, sig_qids, built_qids):
    """Why the reranker's view of a library differs from the signals' (empty = identical). Counts and indices only."""
    probs = []
    blocks = meta.get("block_ids") or []
    if lib.n != meta.get("passages", len(blocks)) or lib.n != len(blocks):
        probs.append(f"passages: library {lib.n}, signals {meta.get('passages', len(blocks))}")
    elif list(lib.p_block) != list(blocks):
        first = next(i for i, (x, y) in enumerate(zip(lib.p_block, blocks)) if x != y)
        probs.append(f"block IDs differ at passage index {first} (of {lib.n})")
    nodes = meta.get("node_ids")
    if nodes is not None and list(lib.node_ids) != list(nodes):
        probs.append(f"entries: library {len(lib.node_ids)}, signals {len(nodes)} (or a different order)")
    rows_p = np.asarray(rows_p)
    if len(rows_p) == 0:
        probs.append("signals have 0 pool rows")
    elif int(rows_p.max()) >= lib.n:
        probs.append(f"pool rows pointing past the library: {int((rows_p >= lib.n).sum())} of {len(rows_p)} "
                     f"(max passage index {int(rows_p.max())}, library has {lib.n})")
    built = set(built_qids)
    missing = [q for q in sig_qids if q not in built]
    if missing or len(sig_qids) != len(built_qids):
        probs.append(f"questions: signals {len(sig_qids)}, built here {len(built_qids)}, "
                     f"{len(missing)} signal question IDs not built here (first: {missing[0] if missing else '-'})")
    return probs


def open_for_signals(lib_name, a, out=None):
    """(lib, {qid: question}, signals json, pool rows, signal qids) for the library the signals were computed on.
    Raises PoolMismatch (counts only) instead of letting a scorer index the wrong passage set."""
    import export, questions as Q
    out = Path(out or OUT)
    sig = json.loads((out / f"signals-{lib_name}.json").read_text())
    rows = dict(np.load(out / f"signals-{lib_name}.npz"))
    meta = sig["meta"]
    arg = {"bench": "bench_nodes", "sample": "sample_nodes", "fixture": "fixture_nodes"}.get(lib_name)
    if arg and not getattr(a, arg, None) and meta.get("nodes_dir"):
        setattr(a, arg, meta["nodes_dir"])
        if lib_name == "bench" and not getattr(a, "bench_root", None):
            a.bench_root = meta.get("bench_root") or str(Path(meta["nodes_dir"]).parent)
    wf = meta.get("wordings_file") or ""
    if wf and not os.environ.get("RELEVANCE_WORDINGS_DIR"):
        os.environ["RELEVANCE_WORDINGS_DIR"] = str(Path(wf).parent)
    lib, keymap = export.open_library(lib_name, a)
    qs, info = Q.build(lib_name, lib, keymap, wordings=bool(wf) and not getattr(a, "no_wordings", False))
    sig_qids = [x["qid"] for x in sig["questions"]]
    probs = alignment_problems(lib, meta, rows["p"], sig_qids, [q["qid"] for q in qs])
    if bool(wf) != bool(info.get("wordings_file")):
        probs.append(f"wordings: signals used {'a wordings file' if wf else 'none'}, here "
                     f"{'a wordings file' if info.get('wordings_file') else 'none'}")
    if probs:
        raise PoolMismatch(f"{lib_name}: the library opened here is not the one the signals used — "
                           + "; ".join(probs) + f". Pass --{arg.replace('_', '-')} <the nodes dir the signals used>"
                           " (or re-run signals.py, which now records it).")
    return lib, {q["qid"]: q for q in qs}, sig, rows, sig_qids


def needed_keys(rows, sig_qids, lib, precision, v):
    return {(precision, v, sig_qids[int(qi)], lib.p_block[int(p)]) for qi, p in zip(rows["q"], rows["p"])}


def score_library(lib_name, a, precision, variants, budget_min=None, t_start=None, out=None, reranker=None):
    """Score every (question, pool passage) for the given variants; resumable from the cache. Refuses (PoolMismatch)
    before touching the cache when the library differs from the signals; after scoring, every pool pair of every
    variant not stopped by the time budget must be in the cache, or RuntimeError (no silent empty cache)."""
    lib, qmap, sig, rows, qids = open_for_signals(lib_name, a, out)
    cache = load_cache(lib_name, out)
    cpath = cache_path(lib_name, out)
    cpath.parent.mkdir(parents=True, exist_ok=True)
    r = reranker or Reranker(precision)
    t_start = t_start or time.time()
    report = {}
    with open(cpath, "a") as f:
        for v in variants:
            todo, seen = [], set()
            for qi, p in zip(rows["q"], rows["p"]):
                q = qmap[qids[int(qi)]]
                key = (precision, v, q["qid"], lib.p_block[int(p)])
                if key not in cache and key not in seen:
                    seen.add(key)
                    todo.append((key, q, int(p)))
            t = time.time()
            for s in range(0, len(todo), 64):
                if budget_min and (time.time() - t_start) / 60 > budget_min:
                    report[v] = {"scored": s, "left": len(todo) - s, "stopped": "time budget"}
                    break
                part = todo[s:s + 64]
                pairs = [(str(q["text"]), str(lib.p_text[p]), str(lib.titles[lib.p_node[p]])) for _, q, p in part]
                sc = r.score(pairs, v)
                if len(sc) != len(part):
                    raise RuntimeError(f"rerank {lib_name} {precision} {v}: {len(sc)} scores for {len(part)} pairs")
                for (key, _, _), x in zip(part, sc):
                    cache[key] = float(x)
                    f.write(json.dumps({"m": key[0], "v": key[1], "q": key[2], "b": key[3], "s": round(float(x), 5)}) + "\n")
                f.flush()
            else:
                report[v] = {"scored": len(todo), "seconds": round(time.time() - t, 1),
                             "ms_per_pair": round(1000 * (time.time() - t) / max(len(todo), 1), 2)}
            need = needed_keys(rows, qids, lib, precision, v)
            have = sum(1 for k in need if k in cache)
            report[v].update({"pool_pairs": len(need), "cached": have})
            say(f"rerank {lib_name} {precision} {v}: {report[v]}")
            if have < len(need) and report[v].get("stopped") != "time budget":
                raise RuntimeError(f"rerank {lib_name} {precision} {v}: {have} of {len(need)} pool pairs in the cache")
    return report


def peak_memory():
    """MLX's peak allocation and this process's max RSS, in MB (both None-safe)."""
    import resource
    out = {"max_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20 if sys.platform == "darwin" else 1 << 10), 1)}
    try:
        import mlx.core as mx
        f = getattr(mx, "get_peak_memory", None) or mx.metal.get_peak_memory
        out["mlx_peak_mb"] = round(f() / (1 << 20), 1)
    except Exception as e:  # noqa: BLE001 — memory is reported, never fatal
        out["mlx_peak_mb"] = None
        out["mlx_peak_error"] = type(e).__name__
    return out


def pool_pairs_for(rows, sig, lib, qmap, qi, k):
    """Today's pool k for one question: its dense top k passages (dense rank order)."""
    sel = [(int(p), int(d)) for q, p, d in zip(rows["q"], rows["p"], rows["dense_rank"]) if q == qi and d >= 0]
    sel = [p for p, d in sorted(sel, key=lambda x: x[1])][:k]
    q = qmap[sig["questions"][qi]["qid"]]
    return [(str(q["text"]), str(lib.p_text[p]), str(lib.titles[lib.p_node[p]])) for p in sel]


def time_reranker(a, precision="bf16", lib_name="bench", pools=(12, 30), variants=("v0",), n_questions=10,
                  out=None, reranker=None, all_wordings=False):
    """Warmed-up timings: ms per question at each pool size (one batch per question), every timed question by ID,
    one-at-a-time ms per pair, peak memory. Questions: library mode, no error, original wording (all wordings with
    `all_wordings`)."""
    lib, qmap, sig, rows, _ = open_for_signals(lib_name, a, out)
    r = reranker or Reranker(precision)
    picks = [i for i, x in enumerate(sig["questions"]) if x.get("mode") == "library" and "error" not in x
             and (all_wordings or int(x.get("wording", 0)) == 0)]
    if n_questions:
        picks = picks[:n_questions]
    if len(picks) < 2:
        raise RuntimeError(f"time {lib_name}: {len(picks)} questions to time")
    res = {"precision": precision, "library": lib_name, "questions_timed": len(picks)}
    r.score(pool_pairs_for(rows, sig, lib, qmap, picks[0], max(pools)), variants[0])  # warm-up
    for v in variants:
        for k in pools:
            per_q = []
            for qi in picks:
                pp = pool_pairs_for(rows, sig, lib, qmap, qi, k)
                t = time.perf_counter(); r.score(pp, v, batch=max(k, 1)); ms = (time.perf_counter() - t) * 1000
                per_q.append([sig["questions"][qi]["qid"], len(pp), round(ms, 1)])
            ms = np.array([x[2] for x in per_q])
            res[f"{v}_pool{k}"] = {"ms_p50": round(float(np.percentile(ms, 50)), 1),
                                   "ms_p95": round(float(np.percentile(ms, 95)), 1),
                                   "ms_max": round(float(ms.max()), 1), "ms_mean": round(float(ms.mean()), 1),
                                   "over_500ms": int((ms > 500).sum()), "over_1s": int((ms > 1000).sum()),
                                   "per_question": per_q}
    single = []
    for pp in pool_pairs_for(rows, sig, lib, qmap, picks[1], 12)[:12]:
        t = time.perf_counter(); r.score([pp], variants[0], batch=1); single.append((time.perf_counter() - t) * 1000)
    res["ms_per_pair_one_at_a_time_p50"] = round(float(np.percentile(single, 50)), 1)
    res["memory"] = peak_memory()
    return res


def smoke(n=10):
    """<= 20 pairs from text in the repo only: each planted bench note's fact sentence vs a Sample Library passage."""
    import random
    from common import SAMPLE_NODES, load_library
    notes = json.loads((BENCHMARK / "notes.json").read_text(encoding="utf-8"))["notes"]
    cases = json.loads((BENCHMARK / "cases-bench.json").read_text(encoding="utf-8"))
    by_key = {x["key"]: x for x in notes}
    turns = [t for c in cases["chats"] for t in c["turns"] if t.get("type") == "fact" and t.get("supports")]
    sample = load_library(SAMPLE_NODES, "sample")
    rnd = random.Random(3)
    pairs, labels = [], []
    for t in turns[:n]:
        note = by_key[t["supports"][0]]
        fact = next((s for s in note["text"].split("\n") if any(f.lower() in s.lower() for alts in t["facts"] for f in alts)),
                    note["text"][:300])
        distract = str(sample.p_text[rnd.randrange(sample.n)])
        pairs += [(t["question"], fact, note["title"]), (t["question"], distract, "")]
        labels += [1, 0]
    r = Reranker("bf16")
    t0 = time.perf_counter()
    s = r.score(pairs)
    ms = (time.perf_counter() - t0) * 1000
    right = sum(1 for i in range(0, len(s), 2) if s[i] > s[i + 1])
    one = r.score(pairs[:4], batch=1)   # right padding must not change a score
    pad_diff = float(np.abs(one - s[:4]).max())
    return {"pairs": len(pairs), "fact_above_distractor": f"{right}/{len(pairs) // 2}",
            "p_yes_fact_median": round(float(np.median(s[0::2])), 3),
            "p_yes_distractor_median": round(float(np.median(s[1::2])), 3), "ms_total_cold": round(ms, 1),
            "padding_max_abs_diff": round(pad_diff, 4), "scores": [round(float(x), 3) for x in s]}


def main():
    refuse_forbidden_ports()
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["download", "convert", "check", "smoke", "verify", "score", "time"])
    ap.add_argument("--lib")
    ap.add_argument("--precision", default="bf16", choices=["bf16", "q4"])
    ap.add_argument("--variants", default="v0")
    ap.add_argument("--budget-min", type=float)
    ap.add_argument("--pairs", type=int, default=10)
    ap.add_argument("--pool", default="12,30", help="time: pool sizes")
    ap.add_argument("--questions", type=int, default=10, help="time: questions to time (0 = all)")
    ap.add_argument("--all-wordings", action="store_true", help="time: every wording, not only the original")
    ap.add_argument("--bench-nodes"); ap.add_argument("--bench-root"); ap.add_argument("--sample-nodes")
    ap.add_argument("--fixture-nodes"); ap.add_argument("--allow-fixture", action="store_true")
    ap.add_argument("--no-wordings", action="store_true")
    a = ap.parse_args()
    v = list(VARIANTS) if a.variants == "all" else a.variants.split(",")
    try:
        if a.cmd == "download":
            download()
        elif a.cmd == "convert":
            convert()
        elif a.cmd == "check":
            ok, d = check_card_and_tokens()
            say(json.dumps({"ok": ok, **d}))
            sys.exit(0 if ok else 1)
        elif a.cmd == "smoke":
            say(json.dumps(smoke(min(a.pairs, 10))))
        elif a.cmd == "verify":
            lib, _, sig, rows, qids = open_for_signals(a.lib or "bench", a)
            say(f"verify {a.lib or 'bench'}: OK · {lib.n} passages, {len(lib.node_ids)} entries, {len(qids)} questions, "
                f"{len(rows['p'])} pool rows match the signals")
        elif a.cmd == "score":
            rep = score_library(a.lib, a, a.precision, v, a.budget_min)
            from common import dump_json
            dump_json(rep, OUT / f"rerank-report-{a.lib}-{a.precision}.json")
        elif a.cmd == "time":
            from common import dump_json
            lib = a.lib or "bench"
            res = time_reranker(a, a.precision, lib, tuple(int(x) for x in a.pool.split(",")), tuple(v), a.questions,
                                all_wordings=a.all_wordings)
            dump_json(res, OUT / f"rerank-timing-{lib}-{a.precision}.json")
            say(json.dumps({k: ({kk: vv for kk, vv in x.items() if kk != "per_question"} if isinstance(x, dict) else x)
                            for k, x in res.items()}))
    except PoolMismatch as e:
        print(f"REFUSED (nothing scored, cache untouched): {e}", file=sys.stderr, flush=True)
        sys.exit(2)
    except RuntimeError as e:
        print(f"FAILED: {e}", file=sys.stderr, flush=True)
        sys.exit(3)


if __name__ == "__main__":
    main()
