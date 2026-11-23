#!/usr/bin/env python3
"""Sweep 2b · 3.2 — tests for the relevance spike (no model, no Simulator, no fixture).

  python3 scripts/librarian/relevance/tests/test_relevance.py

The toy library: 6 passages in 4 entries, BM25 worked out by hand below, and the planted name-without-predicate trap
("What is the capital of France?" vs a travel note that says France and never the capital).
"""
import math
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common as C
import grade as G
import questions as Q
import signals as S

# Passages (tokenizer A tokens in comments; lengths count tokens):
TOY = [
    ("E1", "Paris trip", "We walked along the Seine in France for three days"),  # walked along seine france three day = 6
    ("E1", "Paris trip", "The bakery near our hotel sold croissants"),           # bakery near our hotel sold croissant = 6
    ("E2", "Capital cities", "Paris is the capital of France"),                  # paris capital france = 3
    ("E3", "Espresso log", "Grinder setting fourteen worked for the Ethiopian beans"),  # 6
    ("E4", "Garden", "Setting eleven ran fast"),                                 # 4
    ("E4", "Garden", "Tomatoes need sun and water"),                             # tomatoe need sun water = 4
]
# Hand computation, k1 = 1.2, b = 0.75, N = 6, avgdl = 29 / 6.
#   df(capital) = 1 (p2; title "Capital cities" is E2's, whose only passage is p2) → idf = ln(1 + 5.5 / 1.5) = 1.540445
#   df(france)  = 2 (p0, p2)                                                       → idf = ln(1 + 4.5 / 2.5) = 1.029619
#   p2, title ×0: norm = 0.25 + 0.75 · 3 / 4.8333 = 0.715517, tf' = 1.397590, (tf' · 2.2) / (tf' + 1.2) = 1.183674
#                 → 1.540445 · 1.183674 + 1.029619 · 1.183674 = 3.042117
#   p0, title ×0: norm = 1.181034, tf' = 0.846715, factor 0.910128 → 1.029619 · 0.910128 = 0.937086
#   p2, title ×1: capital tf' = 1.397590 + 1 = 2.397590 → factor 1.466176 → 2.258563 + 1.218733 = 3.477296
#   p2, title ×2: capital tf' = 3.397590 → 3.723167
#   best possible = 1.540445 + 1.029619 = 2.570064 → S2(p0, ×0) = 0.937086 / 2.570064 = 0.364616
HAND = {"idf_capital": 1.540445, "idf_france": 1.029619, "p2w0": 3.042117, "p0w0": 0.937086, "p2w1": 3.477296,
        "p2w2": 3.723167, "best": 2.570064, "S2_p0w0": 0.364616}


def toy_library(s1=None):
    node_ids = ["E1", "E2", "E3", "E4"]
    titles = {"E1": "Paris trip", "E2": "Capital cities", "E3": "Espresso log", "E4": "Garden"}
    vecs = np.eye(6, 8, dtype=np.float32)
    return C.Library("toy", False, node_ids, titles, {n: "" for n in node_ids}, [t[0] for t in TOY],
                     [f"b{i}" for i in range(6)], [t[2] for t in TOY], vecs)


class TestTokenizers(unittest.TestCase):
    def test_a_port(self):
        self.assertEqual(C.tokens_a("What grinder setting worked for the Ethiopian beans?"),
                         ["grinder", "setting", "worked", "ethiopian", "bean"])
        self.assertEqual(C.tokens_a("Capital cities"), ["capital", "city"])

    def test_porter2(self):
        for w, e in [("running", "run"), ("generously", "generous"), ("ponies", "poni"), ("ties", "tie"),
                     ("agreed", "agre"), ("hopping", "hop"), ("hoping", "hope"), ("relational", "relat"),
                     ("knightly", "knight"), ("skies", "sky"), ("dying", "die"), ("news", "news"),
                     ("abilities", "abil"), ("accompanied", "accompani"), ("communication", "communic"),
                     ("consistency", "consist"), ("kneaded", "knead"), ("gaps", "gap"), ("gas", "gas")]:
            self.assertEqual(C.porter2(w), e, w)

    def test_b(self):
        self.assertEqual(C.tokens_b("Café settings at 93 °C, H16 on"), ["cafe", "set", "93", "h16"])

    def test_names_and_predicate(self):
        E, P, _ = C.names_and_predicate("What is the capital of France?", C.tokens_a)
        self.assertEqual((E, P), ({"france"}, ["capital"]))
        E, P, _ = C.names_and_predicate('What did I write about my Bolex H16?', C.tokens_a)
        self.assertEqual(E, {"bolex", "h16"})
        self.assertEqual(C.strip_names("What is the capital of France?"), "What is the capital of ?")
        self.assertEqual(C.named_terms("What did I write? Mara said so"), [])   # sentence-initial → not a name
        self.assertTrue(C.looks_like_ownership("What did I write about coffee"))


class TestBM25(unittest.TestCase):
    def setUp(self):
        self.lib = toy_library()
        self.ix = S.TextIndex(self.lib, "A")
        self.q = C.tokens_a("What is the capital of France?")

    def test_idf(self):
        self.assertEqual(self.q, ["capital", "france"])
        self.assertAlmostEqual(self.ix.idf("capital"), HAND["idf_capital"], places=5)
        self.assertAlmostEqual(self.ix.idf("france"), HAND["idf_france"], places=5)

    def test_scores(self):
        s0, s1, s2 = (self.ix.bm25(self.q, w) for w in (0, 1, 2))
        self.assertAlmostEqual(float(s0[2]), HAND["p2w0"], places=4)
        self.assertAlmostEqual(float(s0[0]), HAND["p0w0"], places=4)
        self.assertAlmostEqual(float(s1[2]), HAND["p2w1"], places=4)
        self.assertAlmostEqual(float(s2[2]), HAND["p2w2"], places=4)
        self.assertEqual(float(s0[1] + s0[3] + s0[4] + s0[5]), 0.0)
        self.assertAlmostEqual(self.ix.best_possible(self.q), HAND["best"], places=5)
        self.assertAlmostEqual(float(s0[0]) / self.ix.best_possible(self.q), HAND["S2_p0w0"], places=5)

    def test_coverage(self):
        cov = self.ix.coverage(self.q)
        self.assertAlmostEqual(float(cov[2]), 1.0, places=6)
        self.assertAlmostEqual(float(cov[0]), HAND["idf_france"] / HAND["best"], places=5)


class TestTrap(unittest.TestCase):
    """The planted name-without-predicate trap: the travel note says France, never the capital."""

    def test_intent_check(self):
        lib = toy_library()
        ix = S.TextIndex(lib, "A")
        E, P, _ = C.names_and_predicate("What is the capital of France?", ix.tok)
        intent = ix.coverage(P) >= G.TAU_P
        name_hit = np.zeros(lib.n, bool)
        for t in E:
            name_hit |= ix.has(t)
        self.assertTrue(name_hit[0] and not intent[0], "travel note: name, no predicate → fails")
        self.assertTrue(name_hit[2] and intent[2], "the capital passage passes")
        # H3 (kept = S1 >= a_hi, or S1 >= a_low and intent) with the September similarities (travel note 0.63)
        S1 = np.array([0.63, 0.40, 0.75, 0.30, 0.30, 0.30])
        a_hi, a_low = 0.70, 0.58
        kept = (S1 >= a_hi) | ((S1 >= a_low) & intent)
        self.assertFalse(kept[0])
        self.assertTrue(kept[2])
        # H2 veto drops the travel note too; T1 at 0.60 keeps it; the BV rule promotes it (france in <= 3 blocks).
        self.assertFalse((S1 >= 0.60)[0] and not (name_hit[0] and not intent[0] and S1[0] < a_hi))
        self.assertTrue((S1 >= 0.60)[0])
        bv = S.BVIndex(lib)
        hits, n_rare = bv.hits("What is the capital of France?")
        self.assertTrue(hits[0] and n_rare >= 1)
        self.assertGreaterEqual(max(S1[0], G.BV_PROMOTE), 0.72)

    def test_s4_france_is_common_english(self):
        common = C.common_english()
        self.assertIn("france", common)
        self.assertGreaterEqual(len(common), 4900)


class TestPlumbing(unittest.TestCase):
    def test_title_match_port(self):
        lib = toy_library()
        lib.titles["E3"] = "Annual – Lab Tests"
        matched, cov = S.title_match("What do my lab test results reveal?", lib)
        self.assertIn("E3", matched)
        self.assertNotIn("E1", matched)

    def test_diversify(self):
        order = [0, 1, 2, 3, 4, 5]
        self.assertEqual(S.diversify(order, ["a", "a", "a", "a", "b", "b"], 3, 4), [0, 1, 2, 4])

    def test_private_never_written(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(RuntimeError):
                C.dump_json({"x": [C.Private("secret")]}, Path(d) / "x.json")
            with self.assertRaises(RuntimeError):
                C.say(C.Private("secret"))
            with self.assertRaises(SystemExit):
                Q.write_embed_input(Path(d) / "in.jsonl", [("a", C.Private("secret"))], fifo=False)

    def test_fifo(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "in.fifo"
            os.mkfifo(p)
            got = []
            def read():
                with open(p) as f:
                    got.append(f.read())
            t = threading.Thread(target=read)
            t.start()
            n = Q.write_embed_input(p, [("q1", C.Private("private text")), ("q2", "plain")], fifo=True)
            t.join(5)
            self.assertEqual(n, 2)
            self.assertEqual(len(got[0].splitlines()), 2)
            self.assertFalse(p.is_file())   # a pipe, not a file on disk

    def test_port_guard(self):
        with self.assertRaises(SystemExit):
            C.refuse_forbidden_ports(["x", "--url", "http://127.0.0.1:11434"], {})
        with self.assertRaises(SystemExit):
            C.refuse_forbidden_ports([], {"X": "localhost:1234/v1"})
        C.refuse_forbidden_ports(["--url", "http://127.0.0.1:11500", "12345"], {"P": "localhost:12345"})


# ---------------------------------------------------------------------------------------------------------------
# Sweep 2b rerun guards (2026-11-23): the reranker must open the signals' passage set, and the grade's supporting
# denominator is the supporting entries IN THE POOL. Toy data only, no model.
import json as _json
import types as _types

import export as _export
import rerank_mlx as RM


class _FakeReranker:
    def __init__(self, broken=False):
        self.broken, self.calls = broken, 0

    def score(self, pairs, variant="v0", batch=16):
        self.calls += 1
        return np.zeros(0, np.float32) if self.broken else np.linspace(0.1, 0.9, len(pairs)).astype(np.float32)


def _write_toy_signals(out, lib_name, passages, block_ids, node_ids, qids, rows_q, rows_p):
    out.mkdir(parents=True, exist_ok=True)
    meta = {"library": lib_name, "passages": passages, "block_ids": block_ids, "node_ids": node_ids,
            "wordings_file": ""}
    (out / f"signals-{lib_name}.json").write_text(_json.dumps({"meta": meta, "questions": [
        {"qid": q, "mode": "library", "wording": 0} for q in qids]}))
    np.savez(out / f"signals-{lib_name}.npz", q=np.array(rows_q), p=np.array(rows_p),
             dense_rank=np.arange(len(rows_p)))


class TestRerankCountGuard(unittest.TestCase):
    """Sweep 2b night: signals on the seeded Sample (712 passages), reranker on the repo's (686) → IndexError × 8 and
    an empty cache. Now a mismatch refuses before the cache is touched, and a short cache fails loudly."""

    def setUp(self):
        self.lib = toy_library()               # 6 passages b0…b5, entries E1…E4
        self.qids = ["sample|C1|0", "sample|C2|0"]
        self._orig = (_export.open_library, Q.build)
        _export.open_library = lambda name, a=None: (self.lib, {})
        Q.build = lambda lib_name, lib, keymap, results=None, wordings=True, gauntlet_entries=True: (
            [{"qid": q, "text": f"question {i}"} for i, q in enumerate(self.qids)], {"wordings_file": ""})
        self.a = _types.SimpleNamespace(sample_nodes=None, no_wordings=False)

    def tearDown(self):
        _export.open_library, Q.build = self._orig

    def test_alignment_problems_counts(self):
        meta = {"passages": 7, "block_ids": [f"b{i}" for i in range(7)], "node_ids": self.lib.node_ids}
        probs = RM.alignment_problems(self.lib, meta, [0, 6], self.qids, self.qids)
        self.assertTrue(any("library 6, signals 7" in x for x in probs), probs)
        self.assertTrue(any("1 of 2" in x for x in probs), probs)
        ok = {"passages": 6, "block_ids": list(self.lib.p_block), "node_ids": self.lib.node_ids}
        self.assertEqual(RM.alignment_problems(self.lib, ok, [0, 5], self.qids, self.qids), [])
        moved = dict(ok, block_ids=["b0", "b2", "b1", "b3", "b4", "b5"])
        self.assertTrue(RM.alignment_problems(self.lib, moved, [0], self.qids, self.qids))
        self.assertTrue(RM.alignment_problems(self.lib, ok, [0], self.qids + ["sample|C3|1"], self.qids))

    def test_mismatch_refuses_and_leaves_no_cache(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            _write_toy_signals(out, "sample", 7, [f"b{i}" for i in range(7)], self.lib.node_ids, self.qids,
                               [0, 0, 1], [1, 6, 2])
            fake = _FakeReranker()
            with self.assertRaises(RM.PoolMismatch) as cm:
                RM.score_library("sample", self.a, "bf16", ["v1"], out=out, reranker=fake)
            self.assertIn("library 6, signals 7", str(cm.exception))
            self.assertFalse(RM.cache_path("sample", out).exists(), "no (empty) cache written on a mismatch")
            self.assertEqual(fake.calls, 0)

    def test_match_scores_every_pool_pair(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            _write_toy_signals(out, "sample", 6, list(self.lib.p_block), self.lib.node_ids, self.qids,
                               [0, 0, 1, 1], [1, 5, 2, 3])
            rep = RM.score_library("sample", self.a, "bf16", ["v1", "v3"], out=out, reranker=_FakeReranker())
            self.assertEqual({v: (r["pool_pairs"], r["cached"]) for v, r in rep.items()}, {"v1": (4, 4), "v3": (4, 4)})
            lines = RM.cache_path("sample", out).read_text().splitlines()
            self.assertEqual(len(lines), 8)
            self.assertEqual({(_json.loads(x)["q"], _json.loads(x)["b"]) for x in lines},
                             {("sample|C1|0", "b1"), ("sample|C1|0", "b5"), ("sample|C2|0", "b2"), ("sample|C2|0", "b3")})
            # resumable: a second run scores nothing new and still checks coverage
            rep2 = RM.score_library("sample", self.a, "bf16", ["v1"], out=out, reranker=_FakeReranker())
            self.assertEqual((rep2["v1"]["scored"], rep2["v1"]["cached"]), (0, 4))

    def test_short_scores_fail_loudly(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            _write_toy_signals(out, "sample", 6, list(self.lib.p_block), self.lib.node_ids, self.qids, [0], [1])
            with self.assertRaises(RuntimeError):
                RM.score_library("sample", self.a, "bf16", ["v1"], out=out, reranker=_FakeReranker(broken=True))

    def test_signals_nodes_dir_is_followed(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            _write_toy_signals(out, "sample", 6, list(self.lib.p_block), self.lib.node_ids, self.qids, [0], [1])
            js = _json.loads((out / "signals-sample.json").read_text())
            js["meta"]["nodes_dir"] = "/seeded/nodes"
            (out / "signals-sample.json").write_text(_json.dumps(js))
            seen = []
            _export.open_library = lambda name, a=None: (seen.append(a.sample_nodes), (self.lib, {}))[1]
            RM.open_for_signals("sample", self.a, out)
            self.assertEqual(seen, ["/seeded/nodes"])
            a2 = _types.SimpleNamespace(sample_nodes="/explicit", no_wordings=False)
            RM.open_for_signals("sample", a2, out)
            self.assertEqual(seen[-1], "/explicit")


def _toy_grade_dir(d):
    """Three cases on one 'bench' library. Rows: (question, passage, entry index, S1, supporting).
    C1 supports E1 + E2 (E2 never reaches the pool) · C2 supports E2 · C3 no evidence."""
    rows = [(0, 0, 0, 0.90, True), (0, 1, 0, 0.40, True), (0, 3, 2, 0.65, False),
            (1, 2, 1, 0.60, True), (1, 4, 3, 0.55, False),
            (2, 0, 0, 0.30, False)]
    z = {"q": [r[0] for r in rows], "p": [r[1] for r in rows], "node": [r[2] for r in rows],
         "S1": [r[3] for r in rows], "support": [r[4] for r in rows]}
    n = len(rows)
    arr = {k: np.array(v) for k, v in z.items()}
    arr.update({"S6_A": np.ones(n, np.float32), "S3_A": np.ones(n, np.float32), "name_hit_A": np.zeros(n, bool),
                "answer": np.array([r[4] for r in rows])})
    np.savez(Path(d) / "signals-bench.npz", **arr)
    base = {"mode": "library", "followup": False, "type": "", "france": False, "best_s1": 0.9, "named": False,
            "ownership": False}
    qs = [dict(base, qid="bench|C1|0", case="C1", evidence=True, no_evidence=False, supports=["E1", "E2"],
               supports_in_library=["E1", "E2"]),
          dict(base, qid="bench|C2|0", case="C2", evidence=True, no_evidence=False, supports=["E2"],
               supports_in_library=["E2"]),
          dict(base, qid="bench|C3|0", case="C3", evidence=False, no_evidence=True, supports=[],
               supports_in_library=[])]
    meta = {"block_ids": [f"b{i}" for i in range(5)], "entries": 4, "passages": 5}
    (Path(d) / "signals-bench.json").write_text(_json.dumps({"meta": meta, "questions": qs}))


class TestInPoolDenominator(unittest.TestCase):
    def test_keep_all_reaches_the_bar(self):
        with tempfile.TemporaryDirectory() as d:
            _toy_grade_dir(d)
            data = G.Data(["bench"], Path(d), "A")
            self.assertEqual(list(data.q_sup_labelled), [2, 1, 0])
            self.assertEqual(list(data.q_sup_inpool), [1, 1, 0])
            keep = np.ones(len(data.r["q"]), bool)
            m = G.metrics(data, keep, G.entry_kept(data, keep), data.q_bar)
            self.assertEqual((m["sup_kept"], m["sup_total"], m["sup_labelled"], m["sup_out_of_pool"]), (2, 2, 3, 1))
            self.assertEqual(m["sup_missed_cases"], [])   # an out-of-pool label is not a grading miss

    def test_leave_one_case_out_vs_in_sample(self):
        """In sample one cut-off (0.58) keeps both cases' supporting entries; held out, each case gets the cut-off
        its partner alone would pick, and C2 loses its supporting entry: 1 / 2 held out vs 2 / 2 in sample."""
        with tempfile.TemporaryDirectory() as d:
            _toy_grade_dir(d)
            data = G.Data(["bench"], Path(d), "A")
            S1 = data.r["S1"]
            arm = ([(0.5,), (0.58,), (0.7,)], lambda p: S1 >= p[0], 1, None)
            qm = {"bench": data.q_bar}
            folds, (gi, meets), cases = G.fit(data, arm, qm, data.q_case)
            self.assertEqual((arm[0][gi], meets), ((0.58,), True))
            self.assertEqual({c: arm[0][folds[c][0]] for c in ("bench:C1", "bench:C2")},
                             {"bench:C1": (0.58,), "bench:C2": (0.7,)})
            rk, gk = G.assemble(data, arm, folds, data.q_case, None)
            held = G.metrics(data, rk, gk, data.q_bar)
            rk_in = arm[1](arm[0][gi])
            ins = G.metrics(data, rk_in, G.entry_kept(data, rk_in), data.q_bar)
            self.assertEqual((held["sup_kept"], held["sup_total"], held["rest_kept"]), (1, 2, 1))
            self.assertEqual((ins["sup_kept"], ins["sup_total"], ins["rest_kept"]), (2, 2, 1))
            self.assertEqual(held["sup_missed_cases"], ["C2"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
