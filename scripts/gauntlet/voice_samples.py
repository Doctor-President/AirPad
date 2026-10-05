#!/usr/bin/env python3
"""Brief CH-A1b — write the OLD-vs-NEW voice samples for T (labelled, NOT blind).

  voice_samples.py <out.md> <arm_dir>...      each arm_dir holds store passes `old/` and `new/` (graded)
  voice_samples.py --iteration2 <out.md> <arm_dir>...   passes `old-r1..3` / `new2-r1..3` (accuracy table + answers)

Per question: each model's OLD answer directly above its NEW answer, with word count, chips and the graders
(every Gauntlet v2 grader incl. the voice graders W1–W3)."""
import json, os, sys, glob
sys.path.insert(0, os.path.dirname(__file__))
import gauntlet as G

ORDER = ["S1", "S2", "1", "BXc"]
KIND = {"S1": "synthesis", "S2": "synthesis", "1": "read", "BXc": "fact (follow-up to the read)"}


def load_pass(d):
    sr = G.load_json(os.path.join(d, "store-rows.json"), {"rows": []})
    grades = G.load_json(os.path.join(d, "grades.json"), {})
    out = {}
    for r in sr["rows"]:
        t = G.load_json(os.path.join(d, f"turn-{r['seq']:03d}.json")) or {}
        g = next((v for k, v in grades.items() if k.startswith(r["case"] + ".")), {})
        out[r["case"]] = dict(turn=t, grade=g, secs=r.get("elapsedSec"))
    return out


def quote(text):
    return "\n".join("> " + ln if ln.strip() else ">" for ln in (text or "(empty)").strip().splitlines())


def grader_line(g):
    res = g.get("results", {})
    reds = [f"{k} {d}".strip() for k, (s, d) in res.items() if s in ("FAIL", "ABORT")]
    flags = [f"{k} {d}".strip() for k, (s, d) in res.items() if s == "FLAG"]
    s = "graders: " + ("**all green**" if not reds else "**RED** — " + "; ".join(reds))
    return s + (" · flagged for CC's read — " + "; ".join(flags) if flags else "")


def main():
    out_md, arms = sys.argv[1], sys.argv[2:]
    data = {}
    for a in arms:
        v = G.load_json(os.path.join(a, "old", "versions.json"), {})
        data[a] = dict(model=v.get("model", os.path.basename(a)), old=load_pass(os.path.join(a, "old")),
                       new=load_pass(os.path.join(a, "new")), versions=v)
    cm = json.load(open(os.path.join(os.path.dirname(__file__), "cases.json")))
    questions = {c["id"]: c["question"] for ch in cm["chats"] for c in ch["cases"]}
    L = []
    for q in ORDER:
        L += [f"## {q} · {KIND[q]} — “{questions.get(q, '')}”", ""]
        for a, d in data.items():
            for which in ("old", "new"):
                row = d[which].get(q)
                if not row:
                    L += [f"### {d['model']} · {which.upper()} — (not run)", ""]
                    continue
                t, g = row["turn"], row["grade"]
                st = g.get("stats", {})
                chips = ", ".join(f"[{c['index']}] {c.get('title', '')[:40]}" for c in (t.get("citations") or []))
                L += [f"### {d['model']} · {which.upper()} prompt",
                      f"_{st.get('words', '?')} words · {round(row['secs'] or 0)} s · {t.get('receipt') or 'no receipt'} · "
                      f"chips: {chips or 'none'}_  ",
                      f"_{grader_line(g)}_", "", quote(t.get("finalText")), ""]
        L += ["---", ""]
    run_level = []
    for a, d in data.items():
        for which in ("old", "new"):
            g = G.load_json(os.path.join(a, which, "grades.json"), {})
            st, det = G.run_level(g)["W2"]
            run_level.append(f"{d['model']} {which.upper()}: W2 {st} ({det})")
    L += ["## Run-level", "", *[f"- {x}" for x in run_level], "",
          "<details><summary>The NEW system prompt exactly as sent on S1 (survey turn)</summary>", "",
          "```", next((d["new"]["S1"]["turn"].get("systemPrompt", "") for d in data.values() if "S1" in d["new"]), ""), "```", "", "</details>", ""]
    open(out_md, "a").write("\n".join(L))


def iteration2(out_md, arms, runs=3):
    """Iteration 2: per arm, OLD ×runs vs NEW2 ×runs (store passes old-rN / new2-rN). Appends an accuracy table
    over every run, the full NEW2 run-1 answers, and NEW2 runs 2..N of the read/fact answers (collapsed)."""
    cm = json.load(open(os.path.join(os.path.dirname(__file__), "cases.json")))
    questions = {c["id"]: c["question"] for ch in cm["chats"] for c in ch["cases"]}
    L = ["## Iteration 2 — accuracy over all runs", "",
         "Each cell = one run: words · graders that are red (A6 required facts, A6b status labels vs the entry's ranges, "
         "others) · flags. ✓ = no red grader.", "",
         "| model | prompt | run | 1 (read) | BXc (fact) | S1 | S2 | W2 |", "|---|---|---|---|---|---|---|---|"]
    for a in arms:
        model = G.load_json(os.path.join(a, "new2-r1", "versions.json"), {}).get("model", os.path.basename(a))
        for which, label in (("old", "OLD"), ("new2", "NEW-it2")):
            for r in range(1, runs + 1):
                d = os.path.join(a, f"{which}-r{r}")
                ps = load_pass(d)
                cells = []
                for q in ("1", "BXc", "S1", "S2"):   # the table's column order (ORDER is the answers' section order)
                    row = ps.get(q)
                    if not row:
                        cells.append("—"); continue
                    res = row["grade"].get("results", {})
                    reds = [k for k, (st, _) in res.items() if st in ("FAIL", "ABORT")]
                    cells.append(f"{row['grade'].get('stats', {}).get('words', '?')} w · " + ("**" + ", ".join(reds) + "**" if reds else "✓"))
                w2 = G.run_level(G.load_json(os.path.join(d, "grades.json"), {}))["W2"]
                L.append(f"| {model} | {label} | {r} | " + " | ".join(cells) + f" | {w2[0]} ({w2[1].split(' answers')[0]}) |")
    L += [""]
    for a in arms:
        model = G.load_json(os.path.join(a, "new2-r1", "versions.json"), {}).get("model", os.path.basename(a))
        r1 = load_pass(os.path.join(a, "new2-r1"))
        L += [f"## Iteration 2 — {model} · NEW-it2 prompt, run 1 (full)", ""]
        for q in ORDER:
            row = r1.get(q)
            if not row:
                continue
            t, g = row["turn"], row["grade"]
            chips = ", ".join(f"[{c['index']}] {c.get('title', '')[:40]}" for c in (t.get("citations") or []))
            L += [f"### {q} · {KIND[q]} — “{questions.get(q, '')}”",
                  f"_{g.get('stats', {}).get('words', '?')} words · {round(row['secs'] or 0)} s · {t.get('receipt') or 'no receipt'} · chips: {chips or 'none'}_  ",
                  f"_{grader_line(g)}_", "", quote(t.get("finalText")), ""]
        L += [f"<details><summary>{model} · NEW-it2 runs 2–{runs}: the read + fact answers</summary>", ""]
        for r in range(2, runs + 1):
            ps = load_pass(os.path.join(a, f"new2-r{r}"))
            for q in ("1", "BXc"):
                row = ps.get(q)
                if row:
                    L += [f"#### run {r} · {q} — {row['grade'].get('stats', {}).get('words', '?')} words · {grader_line(row['grade'])}", "",
                          quote(row["turn"].get("finalText")), ""]
        L += ["</details>", ""]
    open(out_md, "a").write("\n".join(L))


if __name__ == "__main__":
    if sys.argv[1] == "--iteration2":
        iteration2(sys.argv[2], sys.argv[3:])
    else:
        main()
