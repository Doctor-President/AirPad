#!/usr/bin/env python3
"""Sweep 2b · 3.1 — the Librarian suite (design.md §5 stage 15, §11 step 3; research.md §4b A6, A7, A8).

  suite.py check                                  wordings / planted files agree with the case files (no app, no model)
  suite.py expand <dir> [--sets bench,sample,planted]
                                                  per-wording case files <dir>/<set>-w<k>.json: the same turn IDs, the
                                                  question replaced by wording k (follow-ups keep their chat)
  suite.py overlay <out.json>                     benchmark/notes.json's notes (same order → same seeded IDs) + planted
  suite.py export-wordings                        wordings-bench.json / wordings-sample.json for the relevance spike
  suite.py grade-run <set> <results.json> <graded.json> [--private] [--cases <expanded cases.json>]
                                                  one run: bench.py's verdict per turn + planted-error check + guarantees
  suite.py scrub <results.json> <app.log>         private runs: drop every text field (answers, packets, receipts)
  suite.py report <runs-root> [--md out] [--json out] [--private-sets fixture-gk] [--ollama-log path] [--line-check path]

Run layout: <runs-root>/<set>/<route-tag>/w<k>-r<rep>/{results.json, graded.json}.

THE GATE (graded by code, R5; a turn that breaks one also fails as a case):
  G1 no-invent        a library turn where the app sent the model no library text never describes an entry
                      (coverage.py's "an entry titled …" test, plus: no title of a nameable entry that was not sent)
  G2 evidence-kept    a case the library supports never goes to the no-match path (planMode "empty" / "none(…)")
  G3 survey-chip      a chip on an entry that was only surveyed (passage / card, not read in full) exists only when
                      the prose cited it inline or named it (no chip by rule); a chip on an entry never sent fails
  G4 no-match-line    when the app takes the no-match path the answer carries the app's line (verbatim in the after
                      build, checked once per night by the runner) and no chip; the line never sits over notes
  G5 delivered (A8)   server route: the prompt tokens the server counted against what was sent — a shortfall
                      (fewer than chars / 6.5: measured 3.8–5.3 chars per Qwen token), a full window, or a server
                      window smaller than asked; plus any "truncating input prompt" line in the server's log
COVERAGE (A6): answer when supported · cites the support (recall) · citation precision · nothing sent / told no match /
no chip when unsupported · not misled by a planted wrong note · conflict told. pass^k (A7): a case passes only when
every wording and repeat passed.

--private (T's fixture): graded.json keeps IDs, verdict kinds and numbers only; `scrub` then blanks the run's text.
"""
from __future__ import annotations

import glob
import json
import os
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parent
BENCHMARK = LIB / "benchmark"
sys.path.insert(0, str(LIB))
sys.dont_write_bytecode = True     # never write into scripts/librarian/ (the proof reads that folder)
import bench  # noqa: E402  (read-only reuse: grade_row, norm, sentences)
import coverage  # noqa: E402  (read-only reuse: invents)

CASES = {"bench": BENCHMARK / "cases-bench.json", "sample": BENCHMARK / "cases-sample.json",
         "fixture-gk": BENCHMARK / "cases-fixture-gk.json", "planted": HERE / "cases-planted.json"}
WORDED = ("bench", "sample", "planted")
NO_MATCH_LINE = "This answer is from the model's general knowledge, not your notes."
MAX_CHARS_PER_TOKEN = 6.5          # A8: measured 3.8–5.3 on the bench (Qwen3.5 4B, 48 turns); above this = cut
ANSWER_KINDS = {"facts", "sides", "forbidden", "no-answer"}
READ_KINDS = {"read", "read-partial"}
# A planted error stated inside a sentence that attributes it or corrects it is fine; stated flat, it is not.
ATTRIBUTED = re.compile(r"\byour (own )?(note|notes|entry|entries|library|log|diary|mum|mom|mother)\b|"
                        r"\byou (wrote|noted|jotted|recorded|have written|had written|mentioned|said)\b|according to|\bclaims?\b|"
                        r"\bbelie(f|ve)|myth|misconception|not true|isn.t true|incorrect|inaccurate|\bfalse\b|"
                        r"popular|commonly|common (idea|belief|saying)|people (think|say|believe)|often said|is said|"
                        r"\bmum\b|\bmom\b|mother", re.I)
NEG_BEFORE = re.compile(r"\b(not|no|never|isn't|aren't|don't|doesn't)\b[^.]*$")


# ---------------------------------------------------------------- files
def load_json(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


def turns_of(doc):
    return [t for c in doc["chats"] for t in c["turns"]]


def wordings():
    d = load_json(HERE / "wordings.json")
    return {k: v for k, v in d.items() if not k.startswith("_")}


def check():
    """Every bench / Sample / planted turn has ≥ 5 distinct wordings, the first being the case's question."""
    w, problems, n = wordings(), [], 0
    for s in WORDED:
        ids = {t["id"]: t for t in turns_of(load_json(CASES[s]))}
        ws = w.get(s, {})
        for i, t in ids.items():
            v = ws.get(i)
            if not v:
                problems.append(f"{s} {i}: no wordings"); continue
            if v[0] != t["question"]:
                problems.append(f"{s} {i}: wording 1 is not the case's question")
            if len(v) < 5 or len(set(x.strip().lower() for x in v)) != len(v):
                problems.append(f"{s} {i}: needs ≥ 5 distinct wordings ({len(v)})")
            if any(not isinstance(x, str) or not x.strip() or "\n" in x for x in v):
                problems.append(f"{s} {i}: an empty or multi-line wording")
            n += len(v)
        for extra in set(ws) - set(ids):
            problems.append(f"{s} {extra}: wordings for a turn that is not a case")
    pn = load_json(HERE / "planted-notes.json")["notes"]
    base = load_json(BENCHMARK / "notes.json")["notes"]
    keys = [x["key"] for x in base + pn]
    titles = [x["title"] for x in base + pn]
    if len(set(keys)) != len(keys): problems.append("planted: a note key repeats a bench key")
    if len(set(titles)) != len(titles): problems.append("planted: a note title repeats a bench title")
    for t in turns_of(load_json(CASES["planted"])):
        for k in t.get("supports") or []:
            if k not in keys: problems.append(f"planted {t['id']}: supports unknown note {k}")
    return problems, n


def wording_count(s):
    return min(len(v) for v in wordings()[s].values())


def expand(outdir, sets=WORDED):
    out = Path(outdir); out.mkdir(parents=True, exist_ok=True)
    w = wordings(); made = []
    for s in sets:
        doc = load_json(CASES[s])
        for k in range(wording_count(s)):
            d = json.loads(json.dumps(doc))
            d["_doc"] = f"GENERATED by suite.py expand — {s}, wording {k + 1}. Edit wordings.json / the case file, not this."
            for t in turns_of(d):
                t["question"] = w[s][t["id"]][k]
            p = out / f"{s}-w{k + 1}.json"
            p.write_text(json.dumps(d, indent=1, ensure_ascii=False), encoding="utf-8")
            made.append(p.name)
    return made


def overlay(out):
    base = load_json(BENCHMARK / "notes.json")
    planted = load_json(HERE / "planted-notes.json")["notes"]
    d = {"_doc": "GENERATED by suite.py overlay — benchmark/notes.json (same order) + suite/planted-notes.json.",
         "notes": base["notes"] + [{k: v for k, v in n.items() if k != "group"} for n in planted]}
    Path(out).write_text(json.dumps(d, indent=1, ensure_ascii=False), encoding="utf-8")
    return len(base["notes"]), len(planted)


def export_wordings():
    """The relevance spike's format (relevance/questions.py load_wordings): {"turns": {id: [wording 2..n]}}."""
    w = wordings(); made = []
    for s in ("bench", "sample"):
        d = {"_doc": f"GENERATED by suite.py export-wordings from wordings.json for the relevance spike: the original question is "
                     f"its wording 0, so these are wordings 2..n. RELEVANCE_WORDINGS_DIR=scripts/librarian/suite.",
             "turns": {i: v[1:] for i, v in w[s].items()}}
        p = HERE / f"wordings-{s}.json"
        p.write_text(json.dumps(d, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        made.append(p.name)
    return made


# ---------------------------------------------------------------- grading one run
def key_map(results, setname):
    """node ID → case key: planted / bench notes by title, Sample entries as 'title:<lowercased>'."""
    notes = load_json(BENCHMARK / "notes.json")["notes"]
    if setname == "planted":
        notes = notes + load_json(HERE / "planted-notes.json")["notes"]
    by_title = {n["title"]: n["key"] for n in notes}
    return {nid: by_title.get(t, "title:" + t.lower()) for nid, t in (results.get("titles") or {}).items()}


def tnorm(s):
    return re.sub(r"[^a-z0-9]+", " ", bench.norm(s)).strip()


def planted_error(case, answer):
    errs = [bench.norm(e) for e in case.get("plantedError") or []]
    if not errs or not answer:
        return None
    for s in bench.sentences(answer):
        n = bench.norm(s)
        for e in errs:
            i = n.find(e)
            if i < 0:
                continue
            # corrected or negated right before the claim ("it's a myth that…", "no, bats are blind is…")
            if ATTRIBUTED.search(s) or NEG_BEFORE.search(n[max(0, i - 30):i]):
                continue
            return s.strip()
    return None


def is_no_match_path(rec):
    return rec.get("planMode") == "empty" or str(rec.get("decision") or "").startswith("empty")


def delivered(row):
    """A8 on one server-route row: (checked, problem or None, chars, counted)."""
    rec = row.get("record") or {}
    req, tok = rec.get("request") or {}, rec.get("tokens") or {}
    counted = tok.get("prompt")
    if row.get("route") != "server" or not req or counted in (None, -1):
        return False, None, None, None
    chars = (req.get("systemChars") or 0) + (req.get("turnChars") or 0) + (req.get("historyChars") or 0)
    if chars <= 0:
        return False, None, None, None
    asked, served = req.get("numCtx"), rec.get("servedNumCtx")
    if counted <= 0 or counted < chars / MAX_CHARS_PER_TOKEN:
        return True, "shortfall", chars, counted
    if asked and counted >= asked - 8:
        return True, "window-full", chars, counted
    if asked and served and served < asked:
        return True, "served-window-smaller", chars, counted
    return True, None, chars, counted


def guarantees(case, row, keys, titles):
    """{name: (applies, ok, detail)} for G1–G5 on one turn."""
    rec = row.get("record") or {}
    lib = row.get("mode") == "library"
    answer = row.get("answer") or ""
    sent = rec.get("sent") or []
    sent_nodes = {s.get("node") for s in sent}
    model = "request" in rec
    g = {}
    # G1
    if lib and model and not sent and answer:
        detail = "describes an entry" if coverage.invents(answer) else None
        if not detail:
            q = tnorm(case.get("question") or "")
            a = " " + tnorm(answer) + " "
            for nid, t in titles.items():
                tn = tnorm(t)
                if nid not in sent_nodes and len(tn) >= 10 and f" {tn} " in a and tn not in q:
                    detail = "names an entry that was not sent"; break
        g["G1"] = (True, detail is None, detail)
    else:
        g["G1"] = (False, True, None)
    # G2
    if lib and case.get("supports"):
        dec = str(rec.get("decision") or "")
        bad = is_no_match_path(rec) or dec.startswith("none(")
        g["G2"] = (True, not bad, f"went to {dec or 'no match'}" if bad else None)
    else:
        g["G2"] = (False, True, None)
    # G3
    chips = [c for c in row.get("chips") or [] if c.get("nodeID")]
    if lib and chips:
        kinds = {}
        for s in sent:
            kinds.setdefault(s.get("node"), set()).add(s.get("kind"))
        inline = {c.get("node") for c in rec.get("cited") or [] if c.get("inline")}
        named = bool((rec.get("answer") or {}).get("titleFallback"))
        bad = []
        for c in chips:
            k = kinds.get(c["nodeID"])
            if not k:
                bad.append("chip on an entry never sent")
            elif not (k & READ_KINDS) and c["nodeID"] not in inline and not named:
                bad.append("chip by rule on a surveyed entry")
        g["G3"] = (True, not bad, "; ".join(sorted(set(bad))) or None)
    else:
        g["G3"] = (False, True, None)
    # G4
    if lib and is_no_match_path(rec) and answer:
        bad = []
        if not row.get("noMatchLine"): bad.append("no-match line missing")
        if chips: bad.append("chip on a no-match answer")
        g["G4"] = (True, not bad, "; ".join(bad) or None)
    elif lib and row.get("noMatchLine") and sent:
        g["G4"] = (True, False, "no-match line over an answer from notes")
    else:
        g["G4"] = (False, True, None)
    # G5
    checked, problem, _, _ = delivered(row)
    g["G5"] = (checked, problem is None, problem)
    return g


def grade_run(setname, results_path, private=False, cases_path=None):
    """cases_path: the expanded file the run used (its questions = that wording); ground truth is the same."""
    res = load_json(results_path)
    cases = {t["id"]: t for t in turns_of(load_json(cases_path or CASES[setname]))}
    keys = key_map(res, setname)
    titles = res.get("titles") or {}
    rows = []
    for row in res.get("rows", []):
        case = cases.get(row.get("id"))
        if not case:
            continue
        base = bench.grade_row(case, row, keys)
        fails = list(base["fails"])
        err = planted_error(case, row.get("answer"))
        if err:
            fails.append("planted-error:" + err[:70])
        g = guarantees(case, row, keys, titles)
        broken = [f"{k}:{d}" for k, (applies, ok, d) in g.items() if applies and not ok]
        chips = [c for c in row.get("chips") or [] if c.get("nodeID")]
        chip_keys = [keys.get(c["nodeID"], "other") for c in chips]
        supports = set(case.get("supports") or [])
        checked, problem, chars, counted = delivered(row)
        rec = row.get("record") or {}
        out = {
            "id": case["id"], "type": case.get("type"), "mode": row.get("mode"),
            "pass": not fails and not broken, "quality": not fails,
            "fails": [f.split(":")[0] for f in fails] if private else fails,
            "guarantees": {k: {"applies": a, "ok": ok, "detail": d} for k, (a, ok, d) in g.items()},
            "broken": [b.split(":")[0] for b in broken],
            "brokenDetail": [] if private else broken,
            "evidence": bool(supports) and row.get("mode") == "library",
            "noMatchCase": bool(case.get("noMatch")) and row.get("mode") == "library",
            "conflict": bool(case.get("sides")), "planted": bool(case.get("plantedError")),
            "mustCite": bool(case.get("mustCite")),
            "chips": len(chips), "supportedChips": sum(1 for k in chip_keys if k in supports),
            "citesSupport": bool(set(chip_keys) & supports),
            "sent": len(rec.get("sent") or []), "noMatchPath": is_no_match_path(rec),
            "told": bool(row.get("noMatchLine")) or bool(bench.NO_MATCH.search(row.get("answer") or "")),
            "modelCalled": "request" in rec,
            "firstMs": base.get("firstMs"), "totalMs": base.get("totalMs"),
            "deliveredChecked": checked, "deliveredProblem": problem, "sentChars": chars, "promptTokens": counted,
            "numCtx": (rec.get("request") or {}).get("numCtx"),
        }
        rows.append(out)
    return {"set": setname, "route": res.get("route"), "model": served_model(res) or res.get("model"),
            "private": private, "rows": rows}


def served_model(res):
    names = [(r.get("record") or {}).get("servedModel") for r in res.get("rows", [])]
    names = [n for n in names if n and n != "?"]
    return max(set(names), key=names.count) if names else None


def scrub(results_path, log_path=None):
    """Private runs: keep IDs, decisions and numbers; blank every text the app wrote (answers, packets, receipts, titles)."""
    p = Path(results_path)
    if p.is_file():
        res = load_json(p)
        res["titles"] = {}
        for r in res.get("rows", []):
            r["answerChars"] = len(r.get("answer") or "")
            for k in ("answer", "packet", "receipt", "error", "question"):
                if k in r: r[k] = ""
            for c in r.get("chips") or []:
                c.pop("title", None); c["url"] = ""
            rec = r.get("record") or {}
            for k in ("packet", "answer", "question", "text", "thinking"):
                if isinstance(rec.get(k), str): rec[k] = ""
        p.write_text(json.dumps(res, indent=1), encoding="utf-8")
    if log_path and Path(log_path).is_file():
        lines = [l for l in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()
                 if re.search(r"\[LibrarianBench\] (index|START|RESULT|ABORT|done|TURN \S+ (BEGIN|END))", l)]
        Path(log_path).write_text("\n".join(re.sub(r" EMPTY \(.*\)$", " EMPTY", l) for l in lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------- the report
def frac(a, b):
    return "-" if not b else f"{a}/{b} ({100 * a / b:.0f} %)"


def sec(v):
    return "-" if v is None else f"{v / 1000:.1f} s"


def load_runs(root):
    runs = {}
    for g in sorted(glob.glob(os.path.join(root, "*", "*", "w*-r*", "graded.json"))):
        parts = Path(g).parts
        setname, tag, wr = parts[-4], parts[-3], parts[-2]
        m = re.match(r"w(\d+)-r(\d+)$", wr)
        if not m:
            continue
        runs.setdefault((setname, tag), []).append((int(m.group(1)), int(m.group(2)), load_json(g)))
    return runs


def summarise(setname, runs):
    """One (set, route): pass^k over wordings × repeats, per wording, per type, the gate, coverage, A8."""
    per_case, by_w, by_type = {}, {}, {}
    gate = {k: [0, 0] for k in ("G1", "G2", "G3", "G4", "G5")}
    violations = []
    c = dict(sup=0, supAns=0, ev=0, evCited=0, cite=0, citeOK=0, chips=0, goodChips=0, uns=0, unsNone=0, unsTold=0,
             unsNoChip=0, planted=0, plantedOK=0, conf=0, confOK=0, turns=0, passed=0)
    first, whole, ratios, a8 = [], [], [], dict(checked=0, problems=0, maxPrompt=0, numCtx=None)
    model = route = None
    for w, rep, g in runs:
        model, route = g.get("model") or model, g.get("route") or route
        for r in g["rows"]:
            c["turns"] += 1; c["passed"] += r["pass"]
            per_case.setdefault(r["id"], {"type": r["type"], "runs": []})["runs"].append(r["pass"])
            bw = by_w.setdefault(w, [0, 0]); bw[0] += r["pass"]; bw[1] += 1
            for k, v in r["guarantees"].items():
                if v["applies"]:
                    gate[k][1] += 1
                    if not v["ok"]:
                        gate[k][0] += 1
                        violations.append((r["id"], w, rep, k, None if g.get("private") else v["detail"]))
            kinds = set(r["fails"]) if g.get("private") else {f.split(":")[0] for f in r["fails"]}
            if r["evidence"]:
                c["sup"] += 1; c["supAns"] += not (kinds & ANSWER_KINDS)
                c["ev"] += 1; c["evCited"] += r["citesSupport"]
                if r["mustCite"]:
                    c["cite"] += 1; c["citeOK"] += "must-cite" not in kinds and "no-answer" not in kinds
            if r["mode"] == "library":
                c["chips"] += r["chips"]; c["goodChips"] += r["supportedChips"]
            if r["noMatchCase"]:
                c["uns"] += 1; c["unsNone"] += r["sent"] == 0; c["unsTold"] += r["told"]; c["unsNoChip"] += r["chips"] == 0
            if r["planted"]:
                c["planted"] += 1; c["plantedOK"] += "planted-error" not in kinds
            if r["conflict"]:
                c["conf"] += 1; c["confOK"] += "sides" not in kinds and "no-answer" not in kinds
            if r["modelCalled"]:
                if r.get("firstMs") not in (None, -1): first.append(r["firstMs"])
                if r.get("totalMs") not in (None, -1): whole.append(r["totalMs"])
            if r["deliveredChecked"]:
                a8["checked"] += 1; a8["problems"] += bool(r["deliveredProblem"])
                a8["maxPrompt"] = max(a8["maxPrompt"], r["promptTokens"] or 0); a8["numCtx"] = r["numCtx"] or a8["numCtx"]
                if r["promptTokens"]: ratios.append(r["sentChars"] / r["promptTokens"])
    for i, d in per_case.items():
        t = by_type.setdefault(d["type"], [0, 0]); t[1] += 1; t[0] += all(d["runs"])
    reps = sorted({rep for _, rep, _ in runs}); ws = sorted({w for w, _, _ in runs})
    passk = sum(1 for d in per_case.values() if all(d["runs"]))
    full = sum(1 for d in per_case.values() if len(d["runs"]) == len(ws) * len(reps))
    med = lambda v: round(statistics.median(v)) if v else None
    a8["cpt"] = (round(min(ratios), 2), round(statistics.median(ratios), 2), round(max(ratios), 2)) if ratios else None
    return dict(set=setname, model=model, route=route, wordings=len(ws), repeats=len(reps), cases=len(per_case),
                complete=full, passK=passk, pass1=(c["passed"] / c["turns"]) if c["turns"] else None, turns=c["turns"],
                byWording={w: v for w, v in sorted(by_w.items())}, byType=by_type, gate=gate,
                violations=violations, coverage=c, firstMs=med(first), totalMs=med(whole), a8=a8,
                perCase={i: [sum(d["runs"]), len(d["runs"])] for i, d in per_case.items()})


def report(root, private_sets=("fixture-gk",), ollama_log=None, line_check=None):
    runs = load_runs(root)
    trunc = None
    if ollama_log and Path(ollama_log).is_file():
        trunc = sum(1 for l in Path(ollama_log).read_text(errors="replace").splitlines() if re.search(r"truncat", l, re.I))
    line_ok = None
    if line_check and Path(line_check).is_file():
        line_ok = Path(line_check).read_text().strip().startswith("ok")
    sums = {f"{s}/{t}": summarise(s, rs) for (s, t), rs in sorted(runs.items())}
    gate_total = sum(v[0] for s in sums.values() for v in s["gate"].values()) + (trunc or 0) + (line_ok is False)
    out = ["# Librarian suite (sweep 2b · 3.1)", "",
           f"**Gate: {'PASS' if gate_total == 0 else 'FAIL'}** — guarantee breaks {gate_total} "
           f"(no-match line verbatim in the build: {'-' if line_ok is None else ('yes' if line_ok else 'NO')}; "
           f"server-log truncation lines: {'-' if trunc is None else trunc}).", "",
           "## The gate, per library and route (breaks / turns it applies to)", "",
           "| library | model | route | G1 no-invent | G2 evidence kept | G3 survey chip | G4 no-match line | G5 delivered |",
           "|---|---|---|---|---|---|---|---|"]
    for k, s in sums.items():
        out.append(f"| {s['set']} | {s['model']} | {s['route']} | " + " | ".join(f"{s['gate'][g][0]} / {s['gate'][g][1]}" for g in ("G1", "G2", "G3", "G4", "G5")) + " |")
    out += ["", "## pass^k and coverage (A6, A7)", "",
            "| library | model | wordings × repeats | pass^k (every wording passes) | pass@1 (turns) | by wording (1 = original) | answer when supported | cites the support (recall) | citation precision | nothing sent when unsupported | told no match | no chip when unsupported | not misled by a planted note | conflict told | first word | whole turn |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for k, s in sums.items():
        c = s["coverage"]
        bw = " · ".join(f"{w}: {v[0]}/{v[1]}" for w, v in s["byWording"].items())
        incomplete = "" if s["complete"] == s["cases"] else f" ({s['complete']} complete)"
        out.append(f"| {s['set']} | {s['model']} | {s['wordings']} × {s['repeats']} | {frac(s['passK'], s['cases'])}{incomplete} | "
                   f"{frac(c['passed'], c['turns'])} | {bw} | {frac(c['supAns'], c['sup'])} | {frac(c['evCited'], c['ev'])} | "
                   f"{frac(c['goodChips'], c['chips'])} | {frac(c['unsNone'], c['uns'])} | {frac(c['unsTold'], c['uns'])} | "
                   f"{frac(c['unsNoChip'], c['uns'])} | {frac(c['plantedOK'], c['planted'])} | {frac(c['confOK'], c['conf'])} | "
                   f"{sec(s['firstMs'])} | {sec(s['totalMs'])} |")
    out += ["", "## Prompt delivered (A8, server route)", "",
            "| library | model | turns checked | shortfalls | largest prompt / window | chars per token (min / median / max) |", "|---|---|---|---|---|---|"]
    for k, s in sums.items():
        a = s["a8"]
        if a["checked"]:
            out.append(f"| {s['set']} | {s['model']} | {a['checked']} | {a['problems']} | {a['maxPrompt']} / {a['numCtx']} | "
                       f"{' / '.join(map(str, a['cpt'])) if a['cpt'] else '-'} |")
    out += ["", "## By type (cases passing every wording and repeat)", ""]
    for k, s in sums.items():
        out.append(f"- {s['set']} · {s['model']}: " + ", ".join(f"{t} {v[0]}/{v[1]}" for t, v in sorted(s["byType"].items())))
    out += ["", "## Guarantee breaks (case · wording · repeat · guarantee)", ""]
    for k, s in sums.items():
        if not s["violations"]:
            continue
        priv = s["set"] in private_sets
        items = [f"{i} w{w} r{r} {g}" + ("" if priv or not d else f" ({d})") for i, w, r, g, d in s["violations"]]
        out.append(f"- {s['set']} · {s['model']}: " + "; ".join(items))
    out += ["", "## Per case (wordings × repeats passed)", ""]
    for k, s in sums.items():
        out.append(f"- {s['set']} · {s['model']}: " + ", ".join(f"{i} {v[0]}/{v[1]}" for i, v in s["perCase"].items()))
    js = {"gateBreaks": gate_total, "truncationLines": trunc, "lineVerbatim": line_ok, "runs": sums}
    return "\n".join(out) + "\n", js


# ---------------------------------------------------------------- CLI
def main(a):
    if not a:
        raise SystemExit(__doc__)
    cmd = a[0]
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a else d
    if cmd == "check":
        problems, n = check()
        for p in problems: print("PROBLEM", p)
        print(f"{'ok' if not problems else 'FAIL'} · {n} wordings")
        return 1 if problems else 0
    if cmd == "expand":
        sets = tuple(opt("--sets", ",".join(WORDED)).split(","))
        print(" ".join(expand(a[1], sets))); return 0
    if cmd == "overlay":
        b, p = overlay(a[1]); print(f"overlay: {b} bench notes + {p} planted"); return 0
    if cmd == "export-wordings":
        print(" ".join(export_wordings())); return 0
    if cmd == "wordings":
        print(wording_count(a[1])); return 0
    if cmd == "grade-run":
        g = grade_run(a[1], a[2], private="--private" in a, cases_path=opt("--cases"))
        Path(a[3]).write_text(json.dumps(g, indent=1), encoding="utf-8")
        p = sum(r["pass"] for r in g["rows"]); b = sum(len(r["broken"]) for r in g["rows"])
        print(f"pass {p}/{len(g['rows'])} · guarantee breaks {b}"); return 0
    if cmd == "scrub":
        scrub(a[1], a[2] if len(a) > 2 else None); return 0
    if cmd == "report":
        priv = tuple(opt("--private-sets", "fixture-gk").split(","))
        text, js = report(a[1], priv, opt("--ollama-log"), opt("--line-check"))
        if opt("--md"): Path(opt("--md")).write_text(text, encoding="utf-8")
        if opt("--json"): Path(opt("--json")).write_text(json.dumps(js, indent=1), encoding="utf-8")
        print(text); return 0
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
