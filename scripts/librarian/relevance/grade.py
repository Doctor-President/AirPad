#!/usr/bin/env python3
"""Sweep 2b · 3.2 — the grade: arms, leave-one-case-out folds, the frozen fixture pass, the table (Markdown + JSON).

  grade.py [--libs bench,sample,fixture] [--out OUT] [--tok A]

Reads OUT/signals-<lib>.{npz,json} and the reranker cache (OUT/rerank-cache/<lib>.jsonl). Writes OUT/grade.md and
OUT/grade.json: case IDs and numbers only, for every library.

Unit = (question, entry); an entry is kept when any of its pool passages is kept (its best passage). Supporting =
the case's `supports`. Denominator = supporting entries IN THE POOL (a grader can only keep what reached it; a
labelled entry outside the pool is a candidate-finding miss, reported beside as "labelled" and "out of pool").
Bar (design §4): supporting kept >= 95 % of in-pool on bench and on Sample, rest kept <= 10 %.
Cut-offs: one global set fitted on bench + Sample pooled. Held out = leave-one-case-out (all of a case's wordings in
one fold; each case graded with cut-offs fitted on all the others; totals summed over the held-out cases): the
decision numbers. In sample = the one set fitted on every case, shown beside (flatters every arm). Frozen, then
applied once to the fixture. Oracle = fitted per library, in sample. Reranker variants are graded only when every
pool pair of every calibration library in the run is scored (else listed as not graded, with the share scored).
Follow-up turns (search text folded with the previous turn) have their own row; general-mode turns are left out.
"""
from __future__ import annotations

import argparse
import itertools
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import OUT, dump_json, refuse_forbidden_ports, say

TAU_P = 0.5            # the intent check's predicate coverage: fixed, not fitted (design §2 caps fitted numbers)
STOPGAP, STOPGAP_OWN, PASSAGE_BAR = 0.66, 0.60, 0.60
BV_PROMOTE = 0.72
CAL = ("bench", "sample")
SUP_BAR, REST_BAR = 0.95, 0.10


def grid(lo, hi, step):
    return [round(x, 4) for x in np.arange(lo, hi + 1e-9, step)]


S1G = grid(0.50, 0.84, 0.02)
S1LOW = grid(0.40, 0.84, 0.02)
FRAC = grid(0.0, 1.0, 0.05)
# The reranker's P(yes) piles up near 0: the night's bench fit wanted a cut-off under 0.05 (Fable read: ~0.02), so
# the grid starts at 0.001, or R1 cannot reach the supporting bar by construction.
RG = [0.001, 0.002, 0.005, 0.01, 0.02, 0.03, 0.04] + grid(0.05, 0.95, 0.05)


class Data:
    """Rows of every library concatenated, with entry groups and per-question tables."""

    def __init__(self, libs, out=OUT, tok="A"):
        self.libs, parts, self.q, self.meta, self.out = libs, [], [], {}, out
        qoff = 0
        for lib in libs:
            js = json.loads((out / f"signals-{lib}.json").read_text())
            z = dict(np.load(out / f"signals-{lib}.npz"))
            self.meta[lib] = js["meta"]
            blocks = js["meta"].get("block_ids") or []
            z["lib"] = np.array([lib] * len(z["q"]))
            z["block"] = np.array([blocks[p] if blocks else "" for p in z["p"]])
            z["q"] = z["q"] + qoff
            parts.append(z)
            for x in js["questions"]:
                x = dict(x); x["lib"] = lib
                self.q.append(x)
            qoff += len(js["questions"])
        keys = set.intersection(*[set(p) for p in parts]) if parts else set()
        self.r = {k: np.concatenate([p[k] for p in parts]) for k in keys}
        self.tok = tok
        r = self.r
        # intent and name hit for the chosen tokenizer
        r["intent"] = r[f"S6_{tok}"] >= TAU_P
        r["S3"] = r[f"S3_{tok}"]
        r["name_hit"] = r[f"name_hit_{tok}"]
        # entry groups
        gk = r["q"].astype(np.int64) * 1_000_000 + r["node"].astype(np.int64)
        self.gkeys, self.ginv = np.unique(gk, return_inverse=True)
        self.G = len(self.gkeys)
        self.g_q = (self.gkeys // 1_000_000).astype(np.int64)
        self.g_sup = np.zeros(self.G, bool)
        np.logical_or.at(self.g_sup, self.ginv, r["support"])
        # question tables
        nq = len(self.q)
        self.q_lib = np.array([x["lib"] for x in self.q])
        self.q_case = np.array([f"{x['lib']}:{x['case']}" for x in self.q])
        ok = np.array(["error" not in x for x in self.q])
        lib_mode = np.array([x.get("mode") == "library" for x in self.q])
        fu = np.array([bool(x.get("followup")) for x in self.q])
        ev = np.array([bool(x.get("evidence")) for x in self.q])
        ne = np.array([bool(x.get("no_evidence")) for x in self.q])
        self.q_bar = ok & lib_mode & ~fu & (ev | ne)
        self.q_follow = ok & lib_mode & fu & (ev | ne)
        self.q_ev = ev
        self.q_overlap = np.array([x.get("type") == "gk-irrelevant-overlap" for x in self.q])
        self.q_france = np.array([bool(x.get("france")) for x in self.q])
        # Supporting entries per question: labelled (in the library) and in the pool. The bar's denominator is the
        # in-pool count (sweep 2b: 40 / 220 bench and 41 / 240 Sample labelled entries never reach the pool, so the
        # labelled denominator made >= 95 % unreachable and the fitter fell back to "keep nearly everything").
        self.q_sup_labelled = np.array([len(set(x.get("supports_in_library", x.get("supports", []))))
                                        if x.get("evidence") else 0 for x in self.q])
        inpool = np.bincount(self.g_q, weights=self.g_sup, minlength=nq).astype(np.int64)
        self.q_sup_inpool = np.where(ev, inpool, 0)
        self.q_sup_total = self.q_sup_inpool
        self.q_best = np.array([x.get("best_s1", 0.0) for x in self.q])
        self.q_named = np.array([bool(x.get("named")) for x in self.q])
        self.q_own = np.array([bool(x.get("ownership")) for x in self.q])
        self.q_general = ok & ~lib_mode
        self.nq = nq

    def rerank_coverage(self, R):
        """Share of pool rows scored, per library."""
        return {l: float(np.isfinite(R[self.r["lib"] == l]).mean()) if (self.r["lib"] == l).any() else 0.0
                for l in self.libs}

    def rerank(self, precision, variant):
        """R per row from the cache (NaN where not scored)."""
        out = np.full(len(self.r["q"]), np.nan, np.float32)
        for lib in self.libs:
            p = self.out / "rerank-cache" / f"{lib}.jsonl"
            if not p.is_file():
                continue
            cache = {}
            for line in p.read_text().splitlines():
                if line.strip():
                    x = json.loads(line)
                    if x["m"] == precision and x["v"] == variant:
                        cache[(x["q"], x["b"])] = x["s"]
            for i in np.where(self.r["lib"] == lib)[0]:
                k = (self.q[self.r["q"][i]]["qid"], self.r["block"][i])
                if k in cache:
                    out[i] = cache[k]
        return out


# ---------------------------------------------------------------------------------------------------------------
# Arms: name → (parameter grid, rule(rows, params) → bool per row, free numbers, question-level hook)
def arms(d, R=None, rtag=""):
    r = d.r
    S1 = r["S1"]
    A = {}
    A["K0 keep everything in the pool (reference, not a candidate)"] = ([()], lambda p: np.ones(len(S1), bool), 0, None)
    A["T0 today (0.60 + stopgap)"] = ([()], lambda p: S1 >= PASSAGE_BAR, 0, "stopgap")
    A["T1 S1 alone"] = ([(t,) for t in S1LOW], lambda p: S1 >= p[0], 1, None)
    for w in (0, 1, 2):
        s2 = r[f"S2w{w}_{d.tok}"]
        A[f"K1 S2 alone (title ×{w})"] = ([(t,) for t in FRAC], (lambda s: lambda p: s >= p[0])(s2), 1, None)
    A["K2 S3 alone"] = ([(t,) for t in FRAC], lambda p: r["S3"] >= p[0], 1, None)
    A["H1 rescue"] = ([(a, lo, c) for a in S1G for lo in S1LOW if lo < a for c in grid(0.2, 0.8, 0.1)],
                      lambda p: (S1 >= p[0]) | ((S1 >= p[1]) & r["intent"] & (r["S3"] >= p[2])), 3, None)
    A["H2 veto"] = ([(a, hi) for a in S1LOW for hi in S1G if hi > a],
                    lambda p: (S1 >= p[0]) & ~(r["name_hit"] & ~r["intent"] & (S1 < p[1])), 2, None)
    A["H3 stage 5 (kept = strong or possible)"] = (
        [(hi, lo) for hi in S1G for lo in S1LOW if lo < hi],
        lambda p: (S1 >= p[0]) | ((S1 >= p[1]) & r["intent"]), 2, None)
    A["H3e (intent = S6e)"] = (
        [(hi, lo, te) for hi in S1G for lo in S1LOW if lo < hi for te in grid(0.30, 0.80, 0.05)],
        lambda p: (S1 >= p[0]) | ((S1 >= p[1]) & (r["S6e"] >= p[2])), 3, None)
    A["BV September rule (control, must fail)"] = (
        [()], lambda p: np.where(r["bv_hit"], np.maximum(S1, BV_PROMOTE), S1) >= PASSAGE_BAR, 0, "stopgap-bv")
    if R is not None and np.isfinite(R).any():
        Rz = np.nan_to_num(R, nan=0.0)
        A[f"R1 reranker alone{rtag}"] = ([(t,) for t in RG], lambda p: Rz >= p[0], 1, None)
        A[f"R2 reranker or S1 ≥ a_hi{rtag}"] = ([(t, hi) for t in RG for hi in S1G],
                                                 lambda p: (Rz >= p[0]) | (S1 >= p[1]), 2, None)
        A[f"R3 H3 with S6r{rtag}"] = ([(hi, lo, t) for hi in S1G for lo in S1LOW if lo < hi for t in RG],
                                      lambda p: (S1 >= p[0]) | ((S1 >= p[1]) & (Rz >= p[2])), 3, None)
    return A


def question_gate(d, hook):
    """T0's per-question stopgap: no named entry and the best passage under 0.66 (0.60 for "my…") → nothing kept."""
    if hook is None:
        return None
    best = d.q_best.copy()
    if hook == "stopgap-bv":
        r = d.r
        bvs = np.where(r["bv_hit"], np.maximum(r["S1"], BV_PROMOTE), r["S1"])
        np.maximum.at(best, r["q"], bvs)
    bar = np.where(d.q_own, STOPGAP_OWN, STOPGAP)
    return d.q_named | (best >= bar)


def entry_kept(d, row_kept, gate=None):
    g = np.zeros(d.G, bool)
    np.logical_or.at(g, d.ginv, row_kept)
    if gate is not None:
        g &= gate[d.g_q]
    return g


def per_question(d, gk):
    """(supporting kept, rest kept, rest total) per question."""
    sk = np.bincount(d.g_q, weights=(gk & d.g_sup), minlength=d.nq)
    rk = np.bincount(d.g_q, weights=(gk & ~d.g_sup), minlength=d.nq)
    rt = np.bincount(d.g_q, weights=~d.g_sup, minlength=d.nq)
    return sk, rk, rt


def fit(d, A_entry, qmask_by_lib, case_ids, cases_subset=None):
    """Matrices per combo × case, then the best combo for every leave-one-out fold (and for all cases)."""
    grid_, rule, _, hook = A_entry
    gate = question_gate(d, hook)
    cases = sorted(set(case_ids[np.isin(d.q_lib, list(qmask_by_lib))] if cases_subset is None else cases_subset))
    cix = {c: i for i, c in enumerate(cases)}
    q_c = np.array([cix.get(c, -1) for c in case_ids])
    libs = list(qmask_by_lib)
    C, L = len(grid_), len(libs)
    SK = np.zeros((C, L, len(cases))); ST = np.zeros((L, len(cases)))
    RK = np.zeros((C, len(cases))); RT = np.zeros(len(cases))
    for li, lib in enumerate(libs):
        m = qmask_by_lib[lib] & (q_c >= 0)
        np.add.at(ST[li], q_c[m], d.q_sup_total[m])
    allm = np.zeros(d.nq, bool)
    for lib in libs:
        allm |= qmask_by_lib[lib]
    allm &= q_c >= 0
    _, _, rt = per_question(d, np.zeros(d.G, bool))
    np.add.at(RT, q_c[allm], rt[allm])
    for ci, p in enumerate(grid_):
        sk, rk, _ = per_question(d, entry_kept(d, rule(p), gate))
        for li, lib in enumerate(libs):
            m = qmask_by_lib[lib] & (q_c >= 0)
            np.add.at(SK[ci, li], q_c[m], sk[m])
        np.add.at(RK[ci], q_c[allm], rk[allm])

    def choose(exclude=None):
        sk = SK.sum(2); st = ST.sum(1); rk = RK.sum(1); rt = RT.sum()
        if exclude is not None:
            sk = sk - SK[:, :, exclude]; st = st - ST[:, exclude]; rk = rk - RK[:, exclude]; rt = rt - RT[exclude]
        frac = np.where(st > 0, sk / np.maximum(st, 1), 1.0)       # per library
        meets = (frac >= SUP_BAR - 1e-9).all(1)
        rest = rk / max(rt, 1)
        if meets.any():
            cand = np.where(meets)[0]
            best = cand[np.lexsort((-frac.min(1)[cand], rest[cand]))[0]]
            return int(best), True
        return int(np.lexsort((rest, -frac.min(1)))[0]), False

    folds = {c: choose(i) for c, i in cix.items()}
    return folds, choose(), cases


def metrics(d, row_kept, gk, qmask):
    """The table's numbers for one set of questions, from row-level and entry-level kept flags."""
    sk, rk, rt = per_question(d, gk)
    st = d.q_sup_total
    ev = qmask & d.q_ev
    out = {"sup_kept": int(sk[ev].sum()), "sup_total": int(st[ev].sum()),
           "sup_labelled": int(d.q_sup_labelled[ev].sum()),
           "sup_out_of_pool": int((d.q_sup_labelled[ev] - d.q_sup_inpool[ev]).sum()),
           "rest_kept": int(rk[qmask].sum()), "rest_total": int(rt[qmask].sum())}
    ov = qmask & d.q_overlap
    out["overlap_rest_kept"], out["overlap_rest_total"] = int(rk[ov].sum()), int(rt[ov].sum())
    rows_q = qmask[d.r["q"]]
    a = rows_q & d.r["answer"]
    out["answer_kept"], out["answer_total"] = int((row_kept & a).sum()), int(a.sum())
    ps = rows_q & d.r["support"]; pr = rows_q & ~d.r["support"]
    out["passage_sup_kept"], out["passage_sup_total"] = int((row_kept & ps).sum()), int(ps.sum())
    out["passage_rest_kept"], out["passage_rest_total"] = int((row_kept & pr).sum()), int(pr.sum())
    kept_any = np.bincount(d.g_q, weights=gk, minlength=d.nq) > 0
    out["wrong_no_match"] = sorted({d.q_case[i].split(":", 1)[1] for i in np.where(ev & ~kept_any)[0]})
    noev = qmask & ~d.q_ev
    out["still_matched"] = sorted({d.q_case[i].split(":", 1)[1] for i in np.where(noev & kept_any)[0]})
    out["noev_questions"] = int(noev.sum()); out["ev_questions"] = int(ev.sum())
    out["sup_missed_cases"] = sorted({d.q_case[i].split(":", 1)[1] for i in np.where(ev & (sk < st))[0]})
    fr = qmask & d.q_france
    out["france"] = {d.q_case[i].split(":", 1)[1]: ("FAIL" if kept_any[i] else "pass") for i in np.where(fr)[0]}
    return out


def assemble(d, A_entry, folds, case_ids, libs_mask):
    """Held-out kept flags: each case evaluated with its own fold's cut-offs."""
    grid_, rule, _, hook = A_entry
    gate = question_gate(d, hook)
    row_kept = np.zeros(len(d.r["q"]), bool)
    gk = np.zeros(d.G, bool)
    by_combo = defaultdict(list)
    for c, (ci, _) in folds.items():
        by_combo[ci].append(c)
    rows_case = case_ids[d.r["q"]]
    g_case = case_ids[d.g_q]
    for ci, cs in by_combo.items():
        rk = rule(grid_[ci])
        ek = entry_kept(d, rk, gate)
        rm = np.isin(rows_case, cs); gm = np.isin(g_case, cs)
        row_kept[rm] = rk[rm]; gk[gm] = ek[gm]
    return row_kept, gk


def pct(k, t):
    return f"{k}/{t} ({100 * k / t:.0f} %)" if t else "–"


def run(libs, out=OUT, tok="A", precisions=("bf16", "q4")):
    d = Data(libs, out, tok)
    standin = any(d.meta[l].get("standin") for l in libs)
    worded = {l: bool(d.meta[l].get("wordings_file")) for l in libs}
    case_ids = d.q_case
    cal = [l for l in CAL if l in libs]
    qmask = {l: d.q_bar & (d.q_lib == l) for l in libs}
    fmask = {l: d.q_follow & (d.q_lib == l) for l in libs}
    result = {"libraries": {}, "arms": {}, "standin": standin, "tokenizer": tok, "tau_p": TAU_P,
              "wordings": {l: ("3.1 wordings" if worded[l] else "original wordings only") for l in libs}}
    # reranker variants available: graded only when every calibration library in the run is fully scored
    R_sets = [(None, "")]
    result["rerank_not_graded"] = {}
    for prec in precisions:
        for v in ("v0", "v1", "v2", "v3"):
            R = d.rerank(prec, v)
            if not np.isfinite(R).any():
                continue
            cov = d.rerank_coverage(R)
            short = {l: c for l, c in cov.items() if c < 0.999}
            if any(l in cal for l in short):
                result["rerank_not_graded"][f"{prec} {v}"] = {l: round(c, 3) for l, c in cov.items()}
                continue
            tag = "".join(f", {l} {c:.0%} scored" for l, c in short.items())
            R_sets.append((R, f" [{prec} {v}{tag}]"))
    seen = set()
    for R, rtag in R_sets:
        for name, A in arms(d, R, rtag).items():
            if name in seen:
                continue
            seen.add(name)
            row = {"free_numbers": A[2]}
            if cal and len(A[0]) > 1:
                folds, (gi, gmeets), _ = fit(d, A, {l: qmask[l] for l in cal}, case_ids)
                row["global_params"] = [float(x) for x in A[0][gi]]; row["global_meets_bar_in_sample"] = gmeets
                rk_loco, gk_loco = assemble(d, A, folds, case_ids, None)
                gate = question_gate(d, A[3])
                rk_glob = A[1](A[0][gi]); gk_glob = entry_kept(d, rk_glob, gate)
                for l in libs:
                    if l in cal:
                        row[l] = metrics(d, rk_loco, gk_loco, qmask[l]); row[l]["unit"] = "leave-one-case-out"
                        row[l]["global"] = metrics(d, rk_glob, gk_glob, qmask[l])   # in sample
                        o_folds, (oi, ometa), _ = fit(d, A, {l: qmask[l]}, case_ids)
                        rk_o = A[1](A[0][oi]); gk_o = entry_kept(d, rk_o, gate)
                        row[l]["oracle"] = metrics(d, rk_o, gk_o, qmask[l]); row[l]["oracle_params"] = [float(x) for x in A[0][oi]]
                    else:
                        row[l] = metrics(d, rk_glob, gk_glob, qmask[l]); row[l]["unit"] = "frozen global cut-offs, once"
                    row[l]["followups"] = metrics(d, rk_glob, gk_glob, fmask[l])
            else:
                p = A[0][0]
                rk = A[1](p); gk = entry_kept(d, rk, question_gate(d, A[3]))
                row["global_params"] = [float(x) for x in p]
                for l in libs:
                    row[l] = metrics(d, rk, gk, qmask[l]); row[l]["unit"] = "fixed rule"
                    row[l]["followups"] = metrics(d, rk, gk, fmask[l])
            row["passes"] = passes(row, libs)
            row["passes_in_sample"] = passes({l: (row[l].get("global", row[l]) if l in cal else row[l])
                                              for l in libs if l in row}, libs)
            result["arms"][name] = row
    # The reranker variant is chosen on bench + Sample only (R1, leave-one-case-out: lowest pooled "rest kept" among
    # variants meeting the supporting bar, else the highest supporting share), then frozen for the fixture.
    chosen = {}
    for name, row in result["arms"].items():
        if not name.startswith("R1 ") or "[" not in name:
            continue
        prec, v = name.split("[")[1].split("]")[0].split()[:2]
        v = v.rstrip(",")
        cm = [row[l] for l in cal if l in row]
        if not cm:
            continue
        sup = min((m["sup_kept"] / m["sup_total"]) if m["sup_total"] else 1.0 for m in cm)
        rest = sum(m["rest_kept"] for m in cm) / max(1, sum(m["rest_total"] for m in cm))
        key = (sup < SUP_BAR, rest if sup >= SUP_BAR else -sup)
        if prec not in chosen or key < chosen[prec][0]:
            chosen[prec] = (key, v)
    result["rerank_variant_chosen"] = {p: v for p, (_, v) in chosen.items()}
    lrow = logistic_ceiling(d, qmask, case_ids, cal, libs)
    if lrow:
        result["arms"]["L logistic ceiling (S1–S7, not a candidate)"] = lrow
    for l in libs:
        qs = [x for x in d.q if x["lib"] == l]
        m = qmask[l]
        evq = [x for x, mm in zip(d.q, m) if mm and x.get("evidence")]
        result["libraries"][l] = {
            "entries": d.meta[l]["entries"], "passages": d.meta[l]["passages"],
            "questions_in_bar": int(m.sum()), "evidence_questions": len(evq),
            "followup_questions": int(fmask[l].sum()), "general_mode_left_out": int((d.q_general & (d.q_lib == l)).sum()),
            "in_pool_dense": {k: sum(x["in_dense"][k] for x in evq) for k in ("12", "30")},
            "in_pool_fused": {k: sum(x["in_fused"][k] for x in evq) for k in ("12", "30")},
            "in_pool_at_all": sum(x["in_pool"] for x in evq),
            "supporting_labelled": int(d.q_sup_labelled[m & d.q_ev].sum()),
            "supporting_in_pool": int(d.q_sup_inpool[m & d.q_ev].sum()),
            "index_build_ms": d.meta[l]["index_build_ms"],
            "signals_ms_p50": d.meta[l]["signals_ms_p50"], "signals_ms_p95": d.meta[l]["signals_ms_p95"],
            "unresolved_gauntlet": d.meta[l].get("unresolved_gauntlet", []),
        }
    for f in sorted(out.glob("rerank-timing-*.json")):
        t = json.loads(f.read_text())
        for k, x in t.items():
            if isinstance(x, dict):
                x.pop("per_question", None)   # the per-question list stays in the timing file
        result.setdefault("rerank_timing", {})[f.stem[len("rerank-timing-"):]] = t
    return result


def passes(row, libs):
    """Design §4: both bars on bench and Sample, rest <= 10 % and France on the fixture, 0 wrong no-match on Sample."""
    why = []
    for l in libs:
        m = row.get(l)
        if not m:
            continue
        if l in CAL and m["sup_total"] and m["sup_kept"] < SUP_BAR * m["sup_total"] - 1e-9:
            why.append(f"{l} supporting {m['sup_kept']}/{m['sup_total']}")
        if m["rest_total"] and m["rest_kept"] > REST_BAR * m["rest_total"] + 1e-9:
            why.append(f"{l} rest {m['rest_kept']}/{m['rest_total']}")
        if any(v == "FAIL" for v in m["france"].values()):
            why.append(f"{l} France")
        if l == "sample" and m["wrong_no_match"]:
            why.append(f"sample wrong no-match {','.join(m['wrong_no_match'])}")
    return {"pass": not why, "why_not": why}


def logistic_ceiling(d, qmask, case_ids, cal, libs):
    """L: logistic on S1–S7 (entry = best passage by probability), leave-one-case-out; a ceiling only."""
    if not cal:
        return None
    r = d.r
    tk = d.tok
    X = np.stack([r["S1"], r[f"S2w1_{tk}"], r["S3"], r[f"S4_{tk}"], r["S5m"].astype(float), r["S5c"],
                  r[f"S6_{tk}"], r["name_hit"].astype(float), r["S6e"], r["S7"]], 1).astype(np.float64)
    mu, sd = X.mean(0), X.std(0) + 1e-6
    X = np.hstack([(X - mu) / sd, np.ones((len(X), 1))])
    y = r["support"].astype(float)
    calm = np.zeros(d.nq, bool)
    for l in cal:
        calm |= qmask[l]
    rows_case = case_ids[r["q"]]

    def train(mask):
        w = np.zeros(X.shape[1])
        Xm, ym = X[mask], y[mask]
        for _ in range(25):
            p = 1 / (1 + np.exp(-Xm @ w))
            g = Xm.T @ (p - ym) + 1e-2 * w
            H = (Xm * (p * (1 - p))[:, None]).T @ Xm + 1e-2 * np.eye(len(w))
            w -= np.linalg.solve(H, g)
        return w

    def pick_t(prob, qm):
        best = None
        for t in grid(0.02, 0.98, 0.02):
            gk = entry_kept(d, prob >= t)
            m = {l: metrics(d, prob >= t, gk, qm[l] if isinstance(qm, dict) else qm & (d.q_lib == l)) for l in cal}
            ok = all(x["sup_total"] == 0 or x["sup_kept"] >= SUP_BAR * x["sup_total"] for x in m.values())
            rest = sum(x["rest_kept"] for x in m.values()) / max(1, sum(x["rest_total"] for x in m.values()))
            key = (not ok, rest)
            if best is None or key < best[0]:
                best = (key, t)
        return best[1]

    prob_loco = np.zeros(len(y))
    cases = sorted(set(case_ids[calm]))
    for c in cases:
        train_rows = calm[r["q"]] & (rows_case != c)
        w = train(train_rows)
        held = rows_case == c
        prob = 1 / (1 + np.exp(-X @ w))
        t = pick_t(prob, {l: qmask[l] & (case_ids != c) for l in cal})
        prob_loco[held] = (prob[held] >= t)
    w_all = train(calm[r["q"]])
    prob_all = 1 / (1 + np.exp(-X @ w_all))
    t_all = pick_t(prob_all, {l: qmask[l] for l in cal})
    row = {"free_numbers": "11 weights + 1 cut-off (ceiling only)", "global_params": [round(float(t_all), 2)]}
    rk_loco = prob_loco > 0.5
    gk_loco = entry_kept(d, rk_loco)
    rk_g = prob_all >= t_all
    gk_g = entry_kept(d, rk_g)
    for l in libs:
        if l in cal:
            row[l] = metrics(d, rk_loco, gk_loco, qmask[l]); row[l]["unit"] = "leave-one-case-out"
        else:
            row[l] = metrics(d, rk_g, gk_g, qmask[l]); row[l]["unit"] = "frozen global, once"
        row[l]["followups"] = metrics(d, rk_g, gk_g, d.q_follow & (d.q_lib == l))
    row["passes"] = passes(row, libs)
    return row


def to_markdown(res):
    L = []
    pre = "PLUMBING CHECK (stand-in question vectors, not a result) — " if res["standin"] else ""
    L.append(f"# {pre}Keyword-relevance spike: the grade")
    L.append("")
    L.append(f"Tokenizer {res['tokenizer']}; intent check τp = {res['tau_p']} (fixed). Unit = (question, entry); an entry "
             "is kept when any of its pool passages is kept. **Supporting kept is counted against the supporting "
             "entries in the pool** (labelled and out-of-pool counts beside). Bench and Sample: held out = "
             "leave-one-case-out (each case graded with cut-offs fitted on all the others; totals over the held-out "
             "cases), in-sample fit beside. Fixture: the global cut-offs, frozen, applied once. Case IDs and "
             "numbers only.")
    for lib, info in res["libraries"].items():
        wl = res["wordings"][lib]
        L.append("")
        L.append(f"## {pre}{lib} ({info['entries']} entries, {info['passages']} passages) · {wl}")
        L.append("")
        L.append(f"Questions in the bar: {info['questions_in_bar']} ({info['evidence_questions']} with evidence) · "
                 f"follow-ups (own row): {info['followup_questions']} · general mode left out: "
                 f"{info['general_mode_left_out']} · {wl}")
        L.append(f"Supporting entries: {info['supporting_in_pool']} in the pool of {info['supporting_labelled']} "
                 f"labelled ({info['supporting_labelled'] - info['supporting_in_pool']} never reach the pool: a "
                 f"candidate-finding miss, outside the grader's denominator)")
        L.append(f"In pool (evidence questions whose supporting entry is reached): dense top 12 "
                 f"{info['in_pool_dense']['12']}, fused (RRF k = 60) top 12 {info['in_pool_fused']['12']}; top 30 dense "
                 f"{info['in_pool_dense']['30']}, fused {info['in_pool_fused']['30']}; pool at all {info['in_pool_at_all']}"
                 f" of {info['evidence_questions']} · {wl}")
        if info.get("unresolved_gauntlet"):
            L.append(f"Gauntlet cases naming an entry that could not be resolved to an ID (left out): "
                     f"{', '.join(info['unresolved_gauntlet'])}")
        L.append("")
        L.append("| Arm | supporting kept (of in pool) · labelled | rest kept | in sample: supporting · rest | "
                 "overlap class, rest kept | answer passages kept | Phase A unit "
                 "(passages: supporting / rest) | evidence Qs wrongly \"no match\" | no-evidence Qs still matched | "
                 "France | oracle rest kept | cut-offs (in-sample global) | follow-ups: supporting · rest |")
        L.append("|" + "---|" * 13)
        for name, row in res["arms"].items():
            m = row.get(lib)
            if not m:
                continue
            ins, go = "same (fixed rule or frozen)", "–"
            if "global" in m:
                g = m["global"]
                ins = f"{pct(g['sup_kept'], g['sup_total'])} · {pct(g['rest_kept'], g['rest_total'])}"
                go = pct(m['oracle']['rest_kept'], m['oracle']['rest_total'])
            fu = m["followups"]
            L.append(
                f"| {name} | {pct(m['sup_kept'], m['sup_total'])} · {m['sup_labelled']} | "
                f"{pct(m['rest_kept'], m['rest_total'])} | {ins} | "
                f"{pct(m['overlap_rest_kept'], m['overlap_rest_total'])} | {pct(m['answer_kept'], m['answer_total'])} | "
                f"{pct(m['passage_sup_kept'], m['passage_sup_total'])} / {pct(m['passage_rest_kept'], m['passage_rest_total'])} | "
                f"{len(m['wrong_no_match'])} of {m['ev_questions']}{(': ' + ', '.join(m['wrong_no_match'])) if m['wrong_no_match'] else ''} | "
                f"{len(m['still_matched'])} of {m['noev_questions']}{(': ' + ', '.join(m['still_matched'])) if m['still_matched'] else ''} | "
                f"{', '.join(f'{k} {v}' for k, v in m['france'].items()) or '–'} | {go} | "
                f"{row.get('global_params')} | {pct(fu['sup_kept'], fu['sup_total'])} · {pct(fu['rest_kept'], fu['rest_total'])} |")
        L.append("")
        L.append(f"Supporting entries missed, by case (leave-one-case-out / frozen), per arm:")
        for name, row in res["arms"].items():
            m = row.get(lib)
            if m and m["sup_missed_cases"]:
                L.append(f"- {name}: {', '.join(m['sup_missed_cases'])}")
    if res.get("rerank_not_graded"):
        L.append("")
        L.append("Reranker variants NOT graded (a calibration library not fully scored; share of pool rows scored): "
                 + "; ".join(f"{k}: " + ", ".join(f"{l} {c:.0%}" for l, c in cov.items())
                             for k, cov in res["rerank_not_graded"].items()))
    if res.get("rerank_variant_chosen"):
        L.append("")
        L.append("Reranker variant chosen on bench + Sample (R1, leave-one-case-out), frozen for the fixture: " + ", ".join(
            f"{p} {v}" for p, v in res["rerank_variant_chosen"].items()) + " (v0 publisher instruction + passage, v1 "
            "publisher + title, v2 notes-library instruction + passage, v3 notes + title).")
    L.append("")
    L.append(f"## {pre}Pass / fail (design §4 decision rule inputs)")
    L.append("")
    for name, row in res["arms"].items():
        p = row["passes"]
        pi = row.get("passes_in_sample")
        L.append(f"- {name}: held out {'PASS' if p['pass'] else 'no — ' + '; '.join(p['why_not'])}"
                 + (f" · in sample {'PASS' if pi['pass'] else 'no'}" if pi else "")
                 + f" (free numbers: {row['free_numbers']})")
    L.append("")
    L.append(f"## {pre}Time per question")
    L.append("")
    for lib, info in res["libraries"].items():
        L.append(f"- {lib}: index build {info['index_build_ms']} ms once; all cheap signals p50 {info['signals_ms_p50']} ms, "
                 f"p95 {info['signals_ms_p95']} ms per question (this Mac). iPhone: estimate ≈ Mac × 1–2 (unverified).")
    for prec, t in (res.get("rerank_timing") or {}).items():
        L.append(f"- reranker {prec}: {json.dumps(t)} (this Mac, warmed up). iPhone: estimate ≈ Mac × 3 (unverified), "
                 f"plus ~0.4 GB beside the writer model.")
    return "\n".join(L) + "\n"


def main():
    refuse_forbidden_ports()
    ap = argparse.ArgumentParser()
    ap.add_argument("--libs", default="bench,sample,fixture")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--tok", default="A", choices=["A", "B"])
    ap.add_argument("--name", default="grade", help="output stem (default grade → grade.md / grade-tokB.md)")
    a = ap.parse_args()
    out = Path(a.out)
    libs = [l for l in a.libs.split(",") if (out / f"signals-{l}.npz").is_file()]
    res = run(libs, out, a.tok)
    stem = a.name + ("" if a.tok == "A" else "-tokB")
    dump_json(res, out / f"{stem}.json")
    (out / f"{stem}.md").write_text(to_markdown(res), encoding="utf-8")
    say(f"{stem}: {len(res['arms'])} arms × {libs} → {out / f'{stem}.md'}")


if __name__ == "__main__":
    main()
