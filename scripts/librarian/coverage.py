#!/usr/bin/env python3
"""Sweep 2a, amend 21c — coverage numbers per route from a Phase B root (reads what bench.py already graded).

  python3 scripts/librarian/coverage.py <root> [--json out.json] [--private]

<root>/<arm>/<set>-<model>-r<rep>/{results.json,graded.json}. Per library × model × arm, summed over the repeats:
  answer when supported     cases whose answer is in the library: the required facts are in the answer (no facts /
                            sides / forbidden / no-answer failure). Citation is counted separately.
  cites the support         of the cases that must cite: a chip on an entry that supports the answer.
  nothing sent when unsupp. library-mode cases nothing supports: the app sent the model no library text (a code decision).
  says no close match       the same cases: the delivered answer says there is no close match (today the model's wording).
  told no match (either)    the same cases: the answer says so OR the app's own footer reads "No matching entries"
                            (the footer is written by code whenever nothing was sent).
  no chip when unsupported  the same cases: no source chip shown at all.
  chips on unsupporting     chips whose entry does not support the answer / all chips (1 − citation precision).
  describes an entry …      turns where the app sent the model no library text, yet the answer describes an entry
                            ("an entry titled …", "you've got a note …"): an invented source.
  conflict told             conflict cases: the note's claim and the disagreement are both in the answer.
  first word / whole turn   median over model-answered turns.
  delivered                 server route: largest prompt_eval_count vs the window asked for, and whether any turn's
                            characters-per-token is far off the run's median (a silent cut would show as a jump).
Answers and questions are never printed; ids and counts only.
"""
import json, sys, os, glob, statistics, re
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANSWER_KINDS = {"facts", "sides", "forbidden", "no-answer"}
# An answer that describes an entry although the app sent the model no library text: "an entry titled …", "you've got a
# note …". Sentences with a negation ("I didn't find an entry …") do not count.
DESCRIBES = re.compile(r"\b(note|entry|sketch) (titled|called|labell?ed|named)\b|\b(you(?:'|’)ve got|you have|you(?:'|’)ve) (?:\w+ ){0,3}?(note|entry|notes|entries|sketch)\b|\bentries titled\b", re.I)
NEGATED = re.compile(r"\b(didn(?:'|’)t|did not|don(?:'|’)t|do not|doesn(?:'|’)t|does not|couldn(?:'|’)t|could not|haven(?:'|’)t|no|not|nothing|none|isn(?:'|’)t|aren(?:'|’)t|without)\b", re.I)


def invents(answer):
    return any(DESCRIBES.search(x) and not NEGATED.search(x) for x in re.split(r"(?<=[.!?])\s+", answer or ""))


def kinds(row):
    return {f.split(":")[0] for f in row["fails"]}


def load(root):
    runs = {}
    for g in sorted(glob.glob(os.path.join(root, "*", "*", "graded.json"))):
        arm, name = g.split(os.sep)[-3], g.split(os.sep)[-2]
        setname = "fixture-gk" if name.startswith("fixture-gk") else name.split("-", 1)[0]
        tag = name[len(setname) + 1:].rsplit("-r", 1)[0]
        res_path = os.path.join(os.path.dirname(g), "results.json")
        res = json.load(open(res_path)) if os.path.exists(res_path) else {"rows": []}
        runs.setdefault((setname, tag, arm), []).append((json.load(open(g)), res))
    return runs


def cover(setname, pairs):
    cases = {t["id"]: dict(t, mode=t.get("mode") or c.get("mode") or "library")
             for c in json.load(open(HERE / "benchmark" / f"cases-{setname}.json"))["chats"] for t in c["turns"]}
    c = dict(sup=0, supAns=0, cite=0, citeOK=0, uns=0, unsAbstain=0, unsTold=0, unsNoChip=0, unsNoneSent=0, unsFacts=0, unsFactsOK=0, chips=0, badChips=0,
             conf=0, confOK=0, noneSent=0, invented=0, passed=0, total=0, appAnswered=0)
    first, whole, ptoks, ratio_flags, max_prompt, num_ctx, answer_chars = [], [], [], 0, 0, None, []
    per_case_abstain = {}
    for graded, res in pairs:
        recs = {r["id"]: (r.get("record") or {}) for r in res["rows"]}
        answers = {r["id"]: r.get("answer") or "" for r in res["rows"]}
        receipts = {r["id"]: r.get("receipt") or "" for r in res["rows"]}
        ratios = []
        for r in graded["rows"]:
            case = cases.get(r["id"])
            if not case:
                continue
            k = kinds(r)
            c["total"] += 1; c["passed"] += r["pass"]
            c["chips"] += r["chips"]; c["badChips"] += r["unsupportedChips"]
            lib = case["mode"] == "library"
            if lib and r["modelCalled"] and r["sent"] == 0 and r["mode"] == "library":
                c["noneSent"] += 1; c["invented"] += invents(answers.get(r["id"]))
            if case.get("supports") and lib:
                c["sup"] += 1; c["supAns"] += not (k & ANSWER_KINDS)
                if case.get("mustCite"):
                    c["cite"] += 1; c["citeOK"] += "must-cite" not in k and "no-answer" not in k
            if case.get("noMatch") and lib:
                ok = "no-match-unsaid" not in k and "no-answer" not in k
                c["uns"] += 1; c["unsAbstain"] += ok
                c["unsTold"] += ok or (r["sent"] == 0 and "No matching entries" in receipts.get(r["id"], "")); c["unsNoChip"] += r["chips"] == 0; c["unsNoneSent"] += r["sent"] == 0
                per_case_abstain.setdefault(r["id"], [0, 0]); per_case_abstain[r["id"]][0] += ok; per_case_abstain[r["id"]][1] += 1
                if case.get("facts"):
                    c["unsFacts"] += 1; c["unsFactsOK"] += not (k & ANSWER_KINDS)
            if case.get("sides"):
                c["conf"] += 1; c["confOK"] += "sides" not in k and "no-answer" not in k
            if r["modelCalled"]:
                if r.get("firstMs") not in (None, -1): first.append(r["firstMs"])
                if r.get("totalMs") not in (None, -1): whole.append(r["totalMs"])
                if r.get("promptTokens") not in (None, -1): ptoks.append(r["promptTokens"])
                answer_chars.append(r["answerChars"])
            else:
                c["appAnswered"] += 1
            rec = recs.get(r["id"], {})
            req, tok = rec.get("request") or {}, rec.get("tokens") or {}
            if tok.get("prompt") and tok["prompt"] > 0 and req.get("turnChars") is not None:
                chars = (req.get("systemChars") or 0) + (req.get("turnChars") or 0) + (req.get("historyChars") or 0)
                ratios.append((chars / tok["prompt"], r["id"]))
                max_prompt = max(max_prompt, tok["prompt"])
                num_ctx = rec.get("servedNumCtx") or req.get("numCtx") or num_ctx
        if len(ratios) >= 5:
            m = statistics.median(x for x, _ in ratios)
            ratio_flags += sum(1 for x, _ in ratios if x > 1.6 * m)   # far more characters per counted token = a cut prompt
    med = lambda v: round(statistics.median(v)) if v else None
    c.update(firstMs=med(first), totalMs=med(whole), promptTokens=med(ptoks), answerChars=med(answer_chars),
             answerCharsP90=(sorted(answer_chars)[int(len(answer_chars) * 0.9)] if answer_chars else None),
             maxPrompt=max_prompt or None, numCtx=num_ctx, cutSuspects=ratio_flags, repeats=len(pairs),
             model=pairs[0][0]["summary"]["model"], route=pairs[0][0]["summary"]["route"], abstainByCase=per_case_abstain)
    return c


def frac(a, b):
    return "-" if not b else f"{a}/{b} ({100 * a / b:.0f} %)"


def sec(v):
    return "-" if v is None else f"{v / 1000:.1f} s"


def main():
    a = sys.argv[1:]
    js = None
    if "--json" in a:
        i = a.index("--json"); js = a[i + 1]; del a[i:i + 2]
    runs = load(a[0])
    out, alljs = [], {}
    for setname in sorted({k[0] for k in runs}):
        out += [f"### {setname} library", "",
                "| model | route | arm | repeats | answer when supported | cites the support | nothing sent when unsupported (app) | says no close match when unsupported (answer) | told no match (answer or the app's footer) | no chip when unsupported | "
                "chips on unsupporting entries | describes an entry although none was sent | conflict told | first word | whole turn | answer length (median / 9 in 10 under) | delivered |",
                "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for (sn, tag, arm), pairs in sorted(runs.items()):
            if sn != setname:
                continue
            c = cover(setname, pairs)
            alljs[f"{setname}/{tag}/{arm}"] = c
            deliv = "-" if not c["maxPrompt"] or c["route"] == "apple" else f"largest prompt {c['maxPrompt']} of {c['numCtx']}; cut suspects {c['cutSuspects']}"
            out.append(f"| {c['model']} | {c['route']} | {arm} | {c['repeats']} | {frac(c['supAns'], c['sup'])} | {frac(c['citeOK'], c['cite'])} | "
                       f"{frac(c['unsNoneSent'], c['uns'])} | {frac(c['unsAbstain'], c['uns'])} | {frac(c['unsTold'], c['uns'])} | {frac(c['unsNoChip'], c['uns'])} | {frac(c['badChips'], c['chips'])} | {frac(c['invented'], c['noneSent'])} | "
                       f"{frac(c['confOK'], c['conf'])} | {sec(c['firstMs'])} | {sec(c['totalMs'])} | {c['answerChars']} / {c['answerCharsP90']} chars | {deliv} |")
        out.append("")
    text = "\n".join(out)
    print(text)
    if js:
        json.dump(alljs, open(js, "w"), indent=1)


if __name__ == "__main__":
    main()
