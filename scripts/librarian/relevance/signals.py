#!/usr/bin/env python3
"""Sweep 2b · 3.2 — the signals S1–S7 per (question, passage) over a fixed pool per question.

  signals.py --lib bench|sample|fixture --vectors <embed-out.jsonl> [--standin random|zeros]

Writes OUT/signals-<lib>.npz (one row per question × pool passage: IDs as indices, numbers only) and
OUT/signals-<lib>.json (the question table: case IDs, flags, node IDs, the dense top 12 for control C-a, timings).
No text is written for any library. `--standin` replaces the question vectors with stand-ins (a plumbing check, never
a result; the output is marked and grade.py prints that on every line).

BM25: k1 = 1.2, b = 0.75; title as a second field (weight 0 / 1 / 2, b = 0); IDF over passages (passage text ∪ its
entry's title), ln(1 + (N − df + 0.5) / (df + 0.5)). S2 = BM25 / (the best this question could score: every
question word once in a passage of average length) clipped to 1.
"""
from __future__ import annotations

import argparse
import math
import re
import sys
import time
from collections import Counter
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (COMMON_TITLE_WORDS, OUT, TOKENIZERS, common_english, dump_json, names_and_predicate,
                    refuse_forbidden_ports, say, tokens_a)

K1, B = 1.2, 0.75
DENSE_POOL, BM25_POOL, PER_NODE = 30, 30, 3
TITLE_WEIGHTS = (0, 1, 2)
RRF_K = 60
CARD_FLOOR = 0.52


class TextIndex:
    """BM25 / coverage index over one library's passages for one tokenizer."""

    def __init__(self, lib, tok_name):
        tok = TOKENIZERS[tok_name]
        self.tok, self.lib = tok, lib
        n = lib.n
        self.N = max(n, 1)
        node_ix = {nid: i for i, nid in enumerate(lib.node_ids)}
        self.p_nix = np.array([node_ix[x] for x in lib.p_node], dtype=np.int64) if n else np.zeros(0, np.int64)
        text_tf, self.dl = [], np.zeros(n, np.float32)
        for i, t in enumerate(lib.p_text):
            c = Counter(tok(str(t)))
            text_tf.append(c)
            self.dl[i] = sum(c.values())
        self.avgdl = float(self.dl.mean()) if n and self.dl.mean() > 0 else 1.0
        self.title_tf = [Counter(tok(str(lib.titles[nid]))) for nid in lib.node_ids]
        self.post = {}   # term -> (passage idx array, tf array)
        for i, c in enumerate(text_tf):
            for t, f in c.items():
                self.post.setdefault(t, ([], []))
                self.post[t][0].append(i); self.post[t][1].append(f)
        self.post = {t: (np.array(a, np.int64), np.array(b, np.float32)) for t, (a, b) in self.post.items()}
        self.tpost = {}  # term -> node idx array (title)
        for j, c in enumerate(self.title_tf):
            for t in c:
                self.tpost.setdefault(t, []).append(j)
        self.tpost = {t: np.array(v, np.int64) for t, v in self.tpost.items()}
        node_passages = [[] for _ in lib.node_ids]
        for i, j in enumerate(self.p_nix):
            node_passages[j].append(i)
        self.df = {}
        for t in set(self.post) | set(self.tpost):
            s = set(self.post[t][0].tolist()) if t in self.post else set()
            for j in self.tpost.get(t, []):
                s.update(node_passages[j])
            self.df[t] = len(s)
        # Entry document frequency over titles + summaries (the recorder's "rare" rule: in <= 5 % of entries).
        self.edf = Counter()
        for nid in lib.node_ids:
            for t in set(tok(str(lib.titles[nid]) + " " + str(lib.summaries[nid]))):
                self.edf[t] += 1
        self.n_entries = len(lib.node_ids)

    def idf(self, t):
        df = self.df.get(t, 0)
        return math.log(1 + (self.N - df + 0.5) / (df + 0.5))

    def tf_text(self, t):
        out = np.zeros(self.lib.n, np.float32)
        if t in self.post:
            ix, tf = self.post[t]
            out[ix] = tf
        return out

    def tf_title(self, t):
        per_node = np.zeros(len(self.lib.node_ids), np.float32)
        for j in self.tpost.get(t, []):
            per_node[j] = self.title_tf[j][t]
        return per_node[self.p_nix]

    def has(self, t):
        return (self.tf_text(t) > 0) | (self.tf_title(t) > 0)

    def bm25(self, qterms, w):
        s = np.zeros(self.lib.n, np.float32)
        norm = 1 - B + B * self.dl / self.avgdl
        for t in qterms:
            tfp = self.tf_text(t) / norm + w * self.tf_title(t)
            s += self.idf(t) * tfp * (K1 + 1) / (tfp + K1)
        return s

    def best_possible(self, qterms):
        return sum(self.idf(t) for t in qterms)

    def coverage(self, terms):
        tot = sum(self.idf(t) for t in terms)
        if not terms or tot <= 0:
            return None
        acc = np.zeros(self.lib.n, np.float32)
        for t in terms:
            acc += self.idf(t) * self.has(t)
        return acc / tot

    def is_rare_entry(self, t):
        return self.edf.get(t, 0) * 20 <= max(self.n_entries, 20)


def title_match(question, lib):
    """Port of `LibrarianState.titleMatchedEntryIDs` → (matched node set, per-node weighted coverage)."""
    q = set(tokens_a(question))
    titled = [(nid, set(tokens_a(str(lib.titles[nid])))) for nid in lib.node_ids]
    df = Counter(w for _, t in titled for w in t)
    n = float(max(len(titled), 1))
    idf = lambda w: math.log((n + 1) / (df.get(w, 0) + 1)) + 1
    matched, cov = set(), {}
    for nid, t in titled:
        if not t:
            cov[nid] = 0.0
            continue
        shared = t & q
        c = sum(idf(w) for w in shared) / max(sum(idf(w) for w in t), 1e-4)
        cov[nid] = c
        if len(t) >= 2 and len(shared - COMMON_TITLE_WORDS) >= 2 and c >= 0.6:
            matched.add(nid)
    return matched, cov


_BV_WORD = re.compile(r"[a-z0-9]{3,}")


class BVIndex:
    """The September BV rule's rarity: a question word in <= 3 blocks (plain lowercase words, no stop list)."""

    def __init__(self, lib):
        self.sets = [set(_BV_WORD.findall(str(t).lower())) for t in lib.p_text]
        self.df = Counter(w for s in self.sets for w in s)

    def hits(self, question):
        rare = {w for w in set(_BV_WORD.findall(question.lower())) if 1 <= self.df.get(w, 0) <= 3}
        return np.array([bool(rare & s) for s in self.sets], dtype=bool), len(rare)


def diversify(order, p_node, per_node, limit):
    cnt, out = Counter(), []
    for i in order:
        n = p_node[i]
        if cnt[n] >= per_node:
            continue
        cnt[n] += 1
        out.append(int(i))
        if len(out) >= limit:
            break
    return out


def dense_list(s1, p_node, top_k):
    """`CorpusStore.askMatches`: the top max(5k, 60) blocks by cosine, at most 3 per entry, `top_k` of them."""
    pool = max(top_k * 5, 60)
    order = np.argsort(-s1, kind="stable")[:pool]
    return diversify(order, p_node, PER_NODE, top_k)


def compute(lib, questions, vectors, standin=None, seed=7):
    """Signals for every question; returns (rows dict of arrays, question table, meta)."""
    t0 = time.perf_counter()
    idx = {k: TextIndex(lib, k) for k in ("A", "B")}
    bv = BVIndex(lib)
    common = common_english()
    build_s = time.perf_counter() - t0
    rng = np.random.default_rng(seed)
    p_node = lib.p_node
    node_ix = {nid: i for i, nid in enumerate(lib.node_ids)}
    p_nix = idx["A"].p_nix
    rows = {k: [] for k in ("q", "p", "node", "S1", "S6e", "S7", "S5m", "S5c", "support", "answer", "bv_hit",
                            "dense_rank", "bm25_rank")}
    for k in ("A", "B"):
        for w in TITLE_WEIGHTS:
            rows[f"S2w{w}_{k}"] = []
        for f in ("S3", "S4", "S6", "name_hit", "bm25raw"):
            rows[f"{f}_{k}"] = []
    qtable, times = [], []

    def vec(key):
        if standin == "random":
            v = rng.standard_normal(lib.vecs.shape[1]).astype(np.float32)
            return v / np.linalg.norm(v)
        if standin == "zeros":
            return np.zeros(lib.vecs.shape[1], np.float32)
        return vectors.get(key)

    for qi, q in enumerate(questions):
        tq = time.perf_counter()
        text = str(q["text"])
        qv = vec(q["qid"] + ("|aug" if q["followup"] and q["text_aug"] else "|q"))
        if qv is None:
            qtable.append({**_qmeta(q), "error": "no vector"})
            continue
        s1 = lib.vecs @ qv if lib.n else np.zeros(0, np.float32)
        noE = vec(q["qid"] + "|noE") if q["text_noE"] else None
        s6e = lib.vecs @ noE if noE is not None else s1
        tenth = float(np.sort(s1)[-10]) if lib.n >= 10 else float(s1.min() if lib.n else 0)
        s7 = s1 - tenth
        matched, tcov = title_match(text, lib)
        s5m = np.array([lib.p_node[i] in matched for i in range(lib.n)], dtype=bool)
        s5c = np.array([tcov.get(lib.p_node[i], 0.0) for i in range(lib.n)], dtype=np.float32)
        per_tok = {}
        for k, ix in idx.items():
            qterms = list(dict.fromkeys(ix.tok(text)))
            best = ix.best_possible(qterms)
            raw = {w: ix.bm25(qterms, w) for w in TITLE_WEIGHTS}
            s2 = {w: np.minimum(raw[w] / best, 1.0) if best > 0 else np.zeros(lib.n, np.float32) for w in TITLE_WEIGHTS}
            cov = ix.coverage(qterms)
            s3 = cov if cov is not None else np.zeros(lib.n, np.float32)
            # S4: question words rare in this library's entries AND not among the 5,000 commonest English words.
            raw_words = re.findall(r"[^\W_]+", text.lower())
            surface = {}
            for wd in raw_words:
                for t in ix.tok(wd):
                    surface.setdefault(t, set()).add(wd)
            distinct = [t for t in qterms if ix.is_rare_entry(t) and not (t in common or surface.get(t, set()) & common)]
            s4 = np.zeros(lib.n, np.float32)
            for t in distinct:
                s4 += ix.has(t)
            E, P, _ = names_and_predicate(text, ix.tok)
            if not E:
                s6 = s3
            elif not P:
                s6 = np.ones(lib.n, np.float32)
            else:
                s6 = ix.coverage(P)
            nh = np.zeros(lib.n, bool)
            for t in E:
                nh |= ix.has(t)
            per_tok[k] = dict(s2=s2, raw=raw[1], s3=s3, s4=s4, s6=s6, nh=nh)
        # The pool: today's dense list widened to 30 ∪ BM25 (tokenizer A, title weight 1) top 30.
        dense30 = dense_list(s1, p_node, DENSE_POOL)
        braw = per_tok["A"]["raw"]
        bm_order = [int(i) for i in np.argsort(-braw, kind="stable")[:BM25_POOL] if braw[i] > 0]
        pool = list(dict.fromkeys(dense30 + bm_order))
        d_rank = {p: r for r, p in enumerate(dense30)}
        b_rank = {p: r for r, p in enumerate(bm_order)}
        fused = sorted(pool, key=lambda p: -(1 / (RRF_K + d_rank[p] + 1) if p in d_rank else 0)
                       - (1 / (RRF_K + b_rank[p] + 1) if p in b_rank else 0))
        sup = set(q["supports"])
        facts = [str(a).lower() for alts in q["facts"] for a in alts if str(a).strip()]
        bvh, n_rare = bv.hits(text)
        for p in pool:
            rows["q"].append(qi); rows["p"].append(p); rows["node"].append(node_ix[p_node[p]])
            rows["S1"].append(s1[p]); rows["S6e"].append(s6e[p]); rows["S7"].append(s7[p])
            rows["S5m"].append(s5m[p]); rows["S5c"].append(s5c[p])
            rows["support"].append(p_node[p] in sup)
            rows["answer"].append(p_node[p] in sup and any(f in str(lib.p_text[p]).lower() for f in facts))
            rows["bv_hit"].append(bvh[p]); rows["dense_rank"].append(d_rank.get(p, -1))
            rows["bm25_rank"].append(b_rank.get(p, -1))
            for k, v in per_tok.items():
                for w in TITLE_WEIGHTS:
                    rows[f"S2w{w}_{k}"].append(v["s2"][w][p])
                rows[f"S3_{k}"].append(v["s3"][p]); rows[f"S4_{k}"].append(v["s4"][p])
                rows[f"S6_{k}"].append(v["s6"][p]); rows[f"name_hit_{k}"].append(v["nh"][p])
                rows[f"bm25raw_{k}"].append(v["raw"][p])
        top12 = dense_list(s1, p_node, 12)
        card_scores = sorted(((float(lib.card_vecs[n] @ qv), n) for n in lib.node_ids if n in lib.card_vecs),
                             reverse=True)
        meta = _qmeta(q)
        meta.update({
            "best_s1": float(s1.max()) if lib.n else 0.0,
            "named": bool(matched),
            "top12": [[p_node[p], round(float(s1[p]), 4)] for p in top12],
            "cards20": [[n, round(s, 4)] for s, n in card_scores if s >= CARD_FLOOR][:20],
            "pool": len(pool), "supports_in_library": [n for n in q["supports"] if n in node_ix],
            "in_dense": {str(k): bool(sup & {p_node[p] for p in dense30[:k]}) for k in (12, 30)},
            "in_fused": {str(k): bool(sup & {p_node[p] for p in fused[:k]}) for k in (12, 30)},
            "in_pool": bool(sup & {p_node[p] for p in pool}),
            "bv_rare_words": n_rare,
        })
        qtable.append(meta)
        times.append((time.perf_counter() - tq) * 1000)
    arr = {}
    for k, v in rows.items():
        dt = bool if k in ("support", "answer", "bv_hit", "S5m") or k.startswith("name_hit") else (
            np.int64 if k in ("q", "p", "node", "dense_rank", "bm25_rank") else np.float32)
        arr[k] = np.array(v, dtype=dt)
    t = np.array(times) if times else np.zeros(1)
    meta = {"library": lib.name, "standin": standin, "entries": len(lib.node_ids), "passages": lib.n,
            "index_build_ms": round(build_s * 1000, 1), "signals_ms_p50": round(float(np.percentile(t, 50)), 2),
            "signals_ms_p95": round(float(np.percentile(t, 95)), 2), "node_ids": lib.node_ids,
            "block_ids": lib.p_block}
    return arr, qtable, meta


def _qmeta(q):
    return {k: q[k] for k in ("qid", "case", "chat", "wording", "lib", "type", "mode", "supports", "evidence",
                              "no_evidence", "followup", "augmented", "recorded", "has_names", "france")} | {
        "ownership": _own(q)}


def _own(q):
    from common import looks_like_ownership
    return looks_like_ownership(str(q["text"]))


def save(lib_name, arr, qtable, meta, out=OUT):
    out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out / f"signals-{lib_name}.npz", **arr)
    dump_json({"meta": meta, "questions": qtable}, out / f"signals-{lib_name}.json")


def main():
    refuse_forbidden_ports()
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--vectors")
    ap.add_argument("--standin", choices=["random", "zeros"])
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--bench-nodes"); ap.add_argument("--bench-root"); ap.add_argument("--sample-nodes")
    ap.add_argument("--fixture-nodes"); ap.add_argument("--allow-fixture", action="store_true")
    ap.add_argument("--results", help="recorded results.json for follow-up flags (default build/sweep2a/retr-<lib>)")
    ap.add_argument("--no-wordings", action="store_true")
    a = ap.parse_args()
    import export, questions
    lib, keymap = export.open_library(a.lib, a)
    qs, info = questions.build(a.lib, lib, keymap, results=a.results, wordings=not a.no_wordings)
    vecs = questions.load_vectors(a.vectors) if a.vectors else {}
    if not vecs and not a.standin:
        raise SystemExit("no question vectors: pass --vectors <EmbedDump output> (or --standin for a plumbing check)")
    arr, qtable, meta = compute(lib, qs, vecs, standin=a.standin)
    meta.update(info)
    # Which nodes dir these indices refer to, so the reranker opens the same passage set (never the fixture's path).
    meta["nodes_dir"] = None if lib.private else str(Path(lib.source).resolve())
    if a.lib == "bench" and a.bench_root:
        meta["bench_root"] = str(Path(a.bench_root).resolve())
    save(a.lib, arr, qtable, meta, Path(a.out))
    say(f"{a.lib}{' (STAND-IN VECTORS: plumbing check, not a result)' if a.standin else ''}: "
        f"{len(qtable)} questions, {len(arr['q'])} pool rows, index {meta['index_build_ms']} ms, "
        f"signals p50 {meta['signals_ms_p50']} ms / p95 {meta['signals_ms_p95']} ms per question")


if __name__ == "__main__":
    main()
