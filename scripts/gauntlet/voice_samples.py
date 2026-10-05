#!/usr/bin/env python3
"""Brief CH-A1b — write the OLD-vs-NEW voice samples for T (labelled, NOT blind).

  voice_samples.py <out.md> <arm_dir>...      each arm_dir holds store passes `old/` and `new/` (graded)

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


if __name__ == "__main__":
    main()
