#!/usr/bin/env python3
"""Sweep 2a — grade a Librarian benchmark run (results.json from `-LibrarianBench`, see bench.sh) on the DELIVERED answer.

  bench.py grade <cases.json> <results.json> [--md out.md] [--json out.json] [--private]
  bench.py table <graded.json> [<graded.json> ...]        one line per run (route x model), for the report
  bench.py compare <graded-before.json> <graded-after.json>
  bench.py matrix <root>     Phase B: <root>/<arm>/<set>-<model>-r<rep>/graded.json folded into one table per library

Per turn: required facts present, forbidden claims absent, every library citation actually supported (the chip's entry is
one the case lists as supporting), a citation where one is due, provenance honest (general knowledge never dressed as "your
notes"; a no-match said plainly), conflicts shown from both sides. No model judges anything: substrings and the case's own
ground truth, as the gauntlet does. Each failure gets a first-guess CAUSE (routing / retrieval / ranking / cut-off / packet /
prompt-or-model / citation) from the Librarian recorder's record in the row; failures.md reviews them by hand.

--private: the library is a user's (the T-corpus fixture). Nothing but IDs, verdicts and numbers is written.
"""
import json, re, sys, statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent

NOTES_CLAIM = re.compile(r"(according to|based on|from|in|per) your (own )?(notes?|entries|entry|library|journal)|your (notes?|entries|entry|library) (say|says|mention|mentions|show|shows|indicate|indicates|suggest|suggests|record|records|note|notes|state|states)|you (wrote|noted|mentioned|recorded|jotted) ", re.I)
NEGATED = re.compile(r"\b(no|not|n't|n’t|nothing|none|neither|without|couldn|didn|don|doesn|unable|can.t find)\b", re.I)
NO_MATCH = re.compile(r"(couldn.t|could not|didn.t|did not|don.t|do not|unable to|can.t|cannot|wasn.t able to|was not able to) (find|see|locate|spot|turn up)|no (close |exact |direct |relevant |matching |specific )?(match|matches|entry|entries|notes?|mentions?|record|results?)\b|not (in|among|part of) your|nothing (in|about|on|related)|(don.t|do not|doesn.t|does not) (appear|seem|look) to|isn.t (in|covered|mentioned)|aren.t (in|any)|no information (about|on)|not (covered|mentioned|found)|haven.t (written|noted|saved)|nothing (that|which|here|there)|none of (the|your|these|them)|no (sign|trace) of", re.I)
NEWS_HONEST = re.compile(r"(can.t|cannot|unable to|don.t have|do not have|no) (look up|access|browse|search|check|provide|real.time|live|current)|web search|search key|search is off|turn on|real.time|up.to.date|as of my|training data|knowledge cutoff|don.t have access|not able to", re.I)
DATED_HONEST = re.compile(r"as of my|training data|may be out of date|may have changed|might have changed|out of date|knowledge cutoff|can.t confirm|cannot confirm|verify|search the web|last update", re.I)


def norm(s):
    s = (s or "").lower()
    for a, b in ((" ", " "), (" ", " "), (" ", " "), ("’", "'"), ("–", "-"), ("—", "-"), ("‑", "-"), ("**", ""), ("*", "")):
        s = s.replace(a, b)
    return re.sub(r"[ \t]+", " ", s)


def sentences(s):
    return [x for x in re.split(r"(?<=[.!?])\s+|\n+", s) if x.strip()]


def load_cases(path):
    d = json.load(open(path, encoding="utf-8"))
    return d, {t["id"]: t for c in d["chats"] for t in c["turns"]}


def key_maps(results):
    """node id -> the case key of a planted note / a Sample Library entry (its title, lowercased, for sample)."""
    notes = json.load(open(HERE / "benchmark" / "notes.json", encoding="utf-8"))["notes"]
    by_title = {n["title"]: n["key"] for n in notes}
    out = {}
    for nid, title in (results.get("titles") or {}).items():
        out[nid] = by_title.get(title, "title:" + title.lower())
    return out


def cause_guess(case, row, fails, keys):
    """A first guess at the step that caused a failure, from the recorder's record."""
    rec = row.get("record") or {}
    decision = rec.get("decision") or rec.get("generalTool") or "?"
    supports = set(case.get("supports") or [])
    sent = {keys.get(s.get("node"), "?") for s in rec.get("sent", [])}
    scored = {keys.get(p.get("node"), "?") for p in rec.get("passages", [])} | {keys.get(c.get("node"), "?") for c in rec.get("cards", [])}
    kinds = {f.split(":")[0] for f in fails}
    if "no-answer" in kinds:
        return "delivery"
    if "app-expected" in kinds or "model-not-expected" in kinds:
        return "routing"
    if not supports:
        if "unsupported-citation" in kinds or "chips" in kinds:
            return "cut-off" if rec.get("sent") else "citation"
        if "no-match-unsaid" in kinds or "claims-notes" in kinds:
            return "cut-off" if decision not in ("empty", "none(subject)") and row.get("mode") == "library" else "prompt-or-model"
        return "prompt-or-model"
    if kinds & {"facts", "must-cite", "sides", "forbidden"}:
        if row.get("mode") == "library":
            if not (supports & sent):
                return "retrieval" if not (supports & scored) else "ranking-or-cut-off"
            if "must-cite" in kinds and not (kinds & {"facts", "sides", "forbidden"}):
                return "citation"
            return "prompt-or-model"
        return "prompt-or-model"
    if "unsupported-citation" in kinds:
        return "citation" if supports & sent else "ranking-or-cut-off"
    return "prompt-or-model"


def grade_row(case, row, keys):
    fails = []
    ans = norm(row.get("answer"))
    rec = row.get("record") or {}
    mode = row.get("mode")
    supports = set(case.get("supports") or [])
    if not ans:
        fails.append("no-answer:" + (row.get("error") or "empty")[:60])
    # facts
    groups = case.get("facts") or []
    hit = sum(1 for g in groups if any(norm(x) in ans for x in g))
    need = case.get("minFacts", len(groups))
    if ans and hit < need:
        fails.append(f"facts:{hit}/{need}")
    for bad in case.get("forbid") or []:
        if norm(bad) in ans:
            fails.append("forbidden:" + bad)
    for i, side in enumerate(case.get("sides") or []):
        if ans and not any(norm(x) in ans for x in side):
            fails.append("sides:" + ("the note's claim is not reported" if i == 0 else "the conflict is not said"))
    # citations
    chips = [c for c in row.get("chips", []) if c.get("nodeID")]
    chip_keys = [keys.get(c["nodeID"], "other:" + c["nodeID"][:8]) for c in chips]
    unsupported = [k for k in chip_keys if k not in supports]
    if unsupported:
        fails.append(f"unsupported-citation:{len(unsupported)} of {len(chips)}")
    if case.get("mustCite") and ans and not (set(chip_keys) & supports):
        fails.append("must-cite:no chip on a supporting entry")
    if case.get("mustCiteKey") and ans and case["mustCiteKey"] not in chip_keys:
        fails.append("must-cite:" + case["mustCiteKey"])
    if "maxChips" in case and len(row.get("chips", [])) > case["maxChips"]:
        fails.append(f"chips:{len(row.get('chips', []))} > {case['maxChips']}")
    # provenance
    prov = case.get("provenance")
    model_called = "request" in rec
    if prov == "app" and model_called:
        fails.append("app-expected:a model answered where the app should say it itself")
    if prov == "general" and ans:
        for s in sentences(row.get("answer") or ""):
            if NOTES_CLAIM.search(s) and not NEGATED.search(s):
                fails.append("claims-notes:" + s.strip()[:70])
                break
    if prov == "notes" and mode == "library" and row.get("generalKnowledgeLine"):
        fails.append("general-line:shown under an answer from the notes")
    if case.get("noMatch") and mode == "library" and ans and not NO_MATCH.search(row.get("answer") or ""):
        fails.append("no-match-unsaid:does not say it found no close match")
    if case.get("newsHonest") and ans and not NEWS_HONEST.search(row.get("answer") or ""):
        fails.append("news:presents news without a search")
    if case.get("datedHonest") and ans and not (row.get("datedLine") or row.get("generalKnowledgeLine") or DATED_HONEST.search(row.get("answer") or "")):
        fails.append("dated:a current-state answer with no dated-knowledge signal")
    tok = rec.get("tokens") or {}
    out = {
        "id": case["id"], "type": case.get("type"), "mode": mode, "pass": not fails, "fails": fails,
        "cause": cause_guess(case, row, fails, keys) if fails else "",
        "decision": rec.get("decision") or rec.get("generalTool") or "", "sent": len(rec.get("sent", [])),
        "sentEntries": len({s.get("node") for s in rec.get("sent", [])}),
        "chips": len(row.get("chips", [])), "unsupportedChips": len(unsupported),
        "passagesOverBar": sum(1 for p in rec.get("passages", []) if p.get("clearsBar")),
        "topPassage": max((p["score"] for p in rec.get("passages", [])), default=None),
        "cardsOverFloor": rec.get("cardsOverFloor"), "topCard": max((c["score"] for c in rec.get("cards", [])), default=None),
        "promptTokens": tok.get("prompt"), "answerTokens": tok.get("answer"),
        "packetChars": (rec.get("packet") or {}).get("chars"),
        "firstMs": rec.get("firstAnswerMs") or rec.get("firstTokenMs"), "totalMs": rec.get("totalMs"),
        "retrievedMs": rec.get("retrievedMs"), "elapsedSec": row.get("elapsedSec"),
        "modelCalled": model_called, "answerChars": len(row.get("answer") or ""),
        "supportSent": bool(supports & {keys.get(s.get("node"), "?") for s in rec.get("sent", [])}) if supports else None,
    }
    return out


def grade(cases_path, results_path):
    doc, cases = load_cases(cases_path)
    res = json.load(open(results_path, encoding="utf-8"))
    keys = key_maps(res)
    rows = [grade_row(cases[r["id"]], r, keys) for r in res["rows"] if r["id"] in cases]
    by_type = {}
    for r in rows:
        t = by_type.setdefault(r["type"], [0, 0]); t[1] += 1; t[0] += r["pass"]
    causes = {}
    for r in rows:
        if not r["pass"]:
            causes[r["cause"]] = causes.get(r["cause"], 0) + 1

    def med(k):
        v = [r[k] for r in rows if r.get(k) not in (None, -1) and r["modelCalled"]]
        return round(statistics.median(v)) if v else None
    # Which model really answered: the server's own name for it (the app's label can lag a debug model override).
    names = [(r.get("record") or {}).get("servedModel") for r in res["rows"]]
    names = [n for n in names if n and n != "?"]
    served = max(set(names), key=names.count) if names else None
    summary = {
        "library": doc.get("library"), "route": res.get("route"), "model": served or res.get("model"), "window": res.get("window"),
        "nodes": res.get("nodes"), "webKey": res.get("webKey"), "at": res.get("at"),
        "pass": sum(r["pass"] for r in rows), "total": len(rows), "missing": sorted(set(cases) - {r["id"] for r in rows}),
        "byType": {k: f"{v[0]}/{v[1]}" for k, v in sorted(by_type.items())}, "causes": dict(sorted(causes.items(), key=lambda x: -x[1])),
        "unsupportedChips": sum(r["unsupportedChips"] for r in rows), "chips": sum(r["chips"] for r in rows),
        "medianFirstMs": med("firstMs"), "medianTotalMs": med("totalMs"), "medianPromptTokens": med("promptTokens"),
        "medianAnswerTokens": med("answerTokens"), "medianRetrievedMs": med("retrievedMs"),
        "modelCalls": sum(r["modelCalled"] for r in rows),
    }
    return {"summary": summary, "rows": rows}


def md(g, results_path=None, private=False):
    s = g["summary"]
    out = [f"## {s['library']} library · {s['route']} · {s['model']} — {s['pass']}/{s['total']} pass",
           "",
           f"Window {s['window']} tokens · {s['nodes']} entries · web key {'yes' if s['webKey'] else 'no'} · run {s['at']}.",
           f"Median: first word {fmt_ms(s['medianFirstMs'])}, whole turn {fmt_ms(s['medianTotalMs'])}, retrieval {fmt_ms(s['medianRetrievedMs'])}, "
           f"prompt {s['medianPromptTokens']} tokens, answer {s['medianAnswerTokens']} tokens. "
           f"Chips shown {s['chips']}, of which unsupported {s['unsupportedChips']}.",
           "", "By type: " + ", ".join(f"{k} {v}" for k, v in s["byType"].items()) + ".",
           "First-guess causes of the failures: " + (", ".join(f"{k} {v}" for k, v in s["causes"].items()) or "none") + ".", "",
           "| id | type | mode | decision | sent | chips (unsupported) | top passage | summaries over floor | prompt tok | first word | verdict | cause |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in g["rows"]:
        verdict = "PASS" if r["pass"] else "FAIL: " + "; ".join(f.split(":")[0] if private else f for f in r["fails"])
        tp = f"{r['topPassage']:.2f}" if r["topPassage"] is not None else "-"
        out.append(f"| {r['id']} | {r['type']} | {r['mode']} | {r['decision']} | {r['sent']} | {r['chips']} ({r['unsupportedChips']}) | {tp} | "
                   f"{r['cardsOverFloor'] if r['cardsOverFloor'] is not None else '-'} | {r['promptTokens'] if r['promptTokens'] not in (None, -1) else '-'} | "
                   f"{fmt_ms(r['firstMs'])} | {verdict} | {r['cause']} |")
    return "\n".join(out) + "\n"


def fmt_ms(v):
    return "-" if v is None else f"{v / 1000:.1f} s"


def matrix(root, private=False):
    """Phase B: <root>/<arm>/<set>-<model>-r<rep>/graded.json → one table per library: each route × arm, with the
    repeats folded (a case counts as passing only when it passed in every repeat), then the per-type and per-case detail."""
    import glob, os
    runs = {}
    for g in sorted(glob.glob(os.path.join(root, "*", "*", "graded.json"))):
        arm = g.split(os.sep)[-3]
        name = g.split(os.sep)[-2]
        setname, rest = name.split("-", 1) if not name.startswith("fixture-gk") else ("fixture-gk", name[len("fixture-gk-"):])
        tag = rest.rsplit("-r", 1)[0]
        runs.setdefault((setname, tag, arm), []).append(json.load(open(g)))
    out = []
    for setname in sorted({k[0] for k in runs}):
        out += [f"### {setname} library", "",
                "| model | arm | repeats | pass every repeat | pass (mean) | chips on unsupporting entries (mean per run) | first word | whole turn | prompt tokens | top causes |",
                "|---|---|---|---|---|---|---|---|---|---|"]
        detail = {}
        for (sn, tag, arm), gs in sorted(runs.items()):
            if sn != setname:
                continue
            ids = [r["id"] for r in gs[0]["rows"]]
            per = {i: [next((r for r in g["rows"] if r["id"] == i), None) for g in gs] for i in ids}
            allpass = sum(1 for i in ids if all(r and r["pass"] for r in per[i]))
            mean = sum(g["summary"]["pass"] for g in gs) / len(gs)
            uns = sum(g["summary"]["unsupportedChips"] for g in gs) / len(gs)
            chips = sum(g["summary"]["chips"] for g in gs) / len(gs)
            causes = {}
            for g in gs:
                for k, v in g["summary"]["causes"].items():
                    causes[k] = causes.get(k, 0) + v

            def med(k):
                v = [g["summary"][k] for g in gs if g["summary"].get(k) is not None]
                return statistics.median(v) if v else None
            model = gs[0]["summary"]["model"]
            out.append(f"| {model} | {arm} | {len(gs)} | {allpass}/{len(ids)} | {mean:.1f}/{len(ids)} | {uns:.1f} of {chips:.1f} | {fmt_ms(med('medianFirstMs'))} | "
                       f"{fmt_ms(med('medianTotalMs'))} | {med('medianPromptTokens')} | "
                       + ", ".join(f"{k} {v / len(gs):.1f}" for k, v in sorted(causes.items(), key=lambda x: -x[1])[:4]) + " |")
            for i in ids:
                detail.setdefault(i, {})[(model, arm)] = (sum(1 for r in per[i] if r and r["pass"]), len(gs), per[i][0]["type"] if per[i][0] else "?")
        cols = sorted({k for d in detail.values() for k in d})
        out += ["", "Per case (passes of repeats):", "", "| id | type | " + " | ".join(f"{m} {a}" for m, a in cols) + " |", "|---|---|" + "---|" * len(cols)]
        for i, d in detail.items():
            typ = next(iter(d.values()))[2]
            out.append(f"| {i} | {typ} | " + " | ".join(f"{d[c][0]}/{d[c][1]}" if c in d else "-" for c in cols) + " |")
        out.append("")
    return "\n".join(out)


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "grade":
        g = grade(a[1], a[2])
        private = "--private" in a
        text = md(g, a[2], private)
        if "--md" in a:
            Path(a[a.index("--md") + 1]).write_text(text, encoding="utf-8")
        if "--json" in a:
            Path(a[a.index("--json") + 1]).write_text(json.dumps(g, indent=1), encoding="utf-8")
        print(text)
    elif len(a) >= 2 and a[0] == "table":
        print("| library | route | model | pass | unsupported chips | first word | whole turn | prompt tokens | causes |")
        print("|---|---|---|---|---|---|---|---|---|")
        for p in a[1:]:
            s = json.load(open(p))["summary"]
            print(f"| {s['library']} | {s['route']} | {s['model']} | {s['pass']}/{s['total']} | {s['unsupportedChips']}/{s['chips']} | {fmt_ms(s['medianFirstMs'])} | "
                  f"{fmt_ms(s['medianTotalMs'])} | {s['medianPromptTokens']} | {', '.join(f'{k} {v}' for k, v in s['causes'].items())} |")
    elif len(a) == 3 and a[0] == "compare":
        b, c = (json.load(open(p)) for p in a[1:])
        bm = {r["id"]: r for r in b["rows"]}
        print(f"before {b['summary']['pass']}/{b['summary']['total']} → after {c['summary']['pass']}/{c['summary']['total']}; "
              f"unsupported chips {b['summary']['unsupportedChips']} → {c['summary']['unsupportedChips']}")
        for r in c["rows"]:
            o = bm.get(r["id"])
            if o and o["pass"] != r["pass"]:
                print(f"  {r['id']} ({r['type']}): {'FAIL→PASS' if r['pass'] else 'PASS→FAIL ' + '; '.join(r['fails'])}")
    elif len(a) >= 2 and a[0] == "matrix":
        print(matrix(a[1], private="--private" in a))
    else:
        raise SystemExit(__doc__)
