#!/usr/bin/env python3
"""Generate summary-round8.md from results-C1a/C1b/C1c/C2/C3/C4.json (+ results-B3.json).

Round 8 varies ONLY the prompt. Fixed everywhere: default guardrails, title+summary
schema (= Round 7 B3), single-stage, raw content, same 20 nodes. One change per cell:
C1 = buildPrompt verbatim (run 3×); C2 = vocabulary line removed; C3 = transformation
frame; C4 = C3 + triple-quote fence. Mac harness; the device wins on prompt-behaviour.
"""
import json, os, statistics

HD = os.path.dirname(os.path.abspath(__file__))
def load(n):
    with open(os.path.join(HD, n)) as f:
        return json.load(f)

C1 = ["C1a", "C1b", "C1c"]
CELLS = C1 + ["C2", "C3", "C4"]
res = {c: {r["id8"]: r for r in load(f"results-{c}.json")} for c in CELLS}
b3 = {r["id8"]: r for r in load("results-B3.json")}          # Round 7 B3 (title+summary, permissive)
nodes = load("round6-nodes.json")
ALL = [n["id8"] for n in nodes]
setof = {n["id8"]: n["set"] for n in nodes}

def side(r):
    if not r["threw"]: return "-"
    return "input" if r["elapsedMs"] < 500 else "gen"
def cs(r):
    return (f"THREW {side(r)} {r['elapsedMs']}ms") if r["threw"] else (f"ok {r['elapsedMs']}ms")
def esc(s):
    return (s or "").replace("|", "\\|").replace("\n", " ").strip()

# C1 consensus (best of 3)
def c1_threwcount(i): return sum(res[c][i]["threw"] for c in C1)
def c1_consensus(i):  return "threw" if c1_threwcount(i) >= 2 else "cleared"
def c1_median_ms(i):  return int(statistics.median([res[c][i]["elapsedMs"] for c in C1]))
def c1_unstable(i):   return c1_threwcount(i) in (1, 2)

L = []
def w(s=""): L.append(s)

w("# FM Diagnostic — Round 8: prompt surface, not schema")
w()
w("**What this tests.** Rounds 6+7 varied guardrails, schema size, and free-text vs Generable — none varied the "
  "PROMPT. Every cell used `buildPrompt()`, which injects the full 72-tag vocabulary (incl. Masculinity, "
  "Hyper-masculinity, Darkness, Fear, Manipulation, Conflict, Power, Morality, Religion) as a comma-separated line "
  "directly above the user's text — a classifier scoring the payload cannot tell that line is a picklist, not "
  "subject matter. Round 8 varies **only the prompt**; everything else is fixed (default guardrails, title+summary "
  "schema = Round 7 B3, single-stage, raw content, same 20 nodes), one change per cell so any win is attributable.")
w()
w("- **C1** — `buildPrompt()` verbatim (full vocab line). Round 7's B3, **run 3×** (C1a/b/c) for stability.")
w("- **C2** — vocabulary line + tag sentence removed (`Analyze this captured idea.` / `Idea:` / content).")
w("- **C3** — transformation frame (`…written by a person in their personal notes. Restate it more briefly.`).")
w("- **C4** — C3 with the content triple-quote fenced.")
w()
w("> Mac harness, **not device-verified**. ms distinguishes **input-side** throws (<500 ms, deterministic) from "
  "**generation-side** (multi-second, can vary run to run). n=1 per cell except C1 (n=3).")
w()

# ---------- 1. C1 stability ----------
w("## 1. C1 replicate stability (three runs of the identical prompt)")
w()
w("| node | set | C1a | C1b | C1c | threw count | stable? |")
w("|---|---|---|---|---|:--:|---|")
unstable = []
for i in ALL:
    k = c1_threwcount(i)
    st = "unstable" if c1_unstable(i) else "stable"
    if c1_unstable(i): unstable.append(i)
    w(f"| {i} | {setof[i]} | {cs(res['C1a'][i])} | {cs(res['C1b'][i])} | {cs(res['C1c'][i])} | {k}/3 | {st} |")
w()
allthrew = [i for i in ALL if c1_threwcount(i) == 3]
allclear = [i for i in ALL if c1_threwcount(i) == 0]
w(f"- **Threw all 3 runs:** {len(allthrew)} — {', '.join(allthrew) if allthrew else '(none)'}.")
w(f"- **Cleared all 3 runs:** {len(allclear)}.")
if unstable:
    w(f"- ⚠️ **UNSTABLE (threw in 1 or 2 of 3): {len(unstable)} — {', '.join(unstable)}.** C1 is NOT fully "
      f"stable across its own replicates; this caps the confidence of every downstream comparison for these nodes.")
else:
    w("- ✅ **Every node threw either 0/3 or 3/3 — C1 is stable across replicates.** Downstream comparisons "
      "against the C1 consensus are on solid ground.")
w()

# ---------- 2. per-node table C1 consensus / C2 / C3 / C4 ----------
w("## 2. Per-node outcomes — C1 consensus vs C2 vs C3 vs C4")
w()
w("C1 column = best-of-3 consensus (throw count, median ms). ✗=threw, ✓=cleared.")
w()
w("| node | set | C1 (k/3, med ms) | C2 | C3 | C4 |")
w("|---|---|---|---|---|---|")
for i in ALL:
    c1 = f"{'✗' if c1_consensus(i)=='threw' else '✓'} {c1_threwcount(i)}/3 {c1_median_ms(i)}ms"
    w(f"| {i} | {setof[i]} | {c1} | {cs(res['C2'][i])} | {cs(res['C3'][i])} | {cs(res['C4'][i])} |")
w()
for c in ["C2", "C3", "C4"]:
    t = [i for i in ALL if res[c][i]["threw"]]
    w(f"- **{c} threw {len(t)}/20** {'(' + ', '.join(t) + ')' if t else ''}.")
c1thr = [i for i in ALL if c1_consensus(i) == "threw"]
w(f"- **C1 consensus threw {len(c1thr)}/20** {'(' + ', '.join(c1thr) + ')' if c1thr else ''}.")
w()

# ---------- 3. HEADLINE: C2 clears what C1 threw ----------
w("## 3. [HEADLINE] Nodes that clear in C2 but threw in C1 — is the vocabulary line implicated?")
w()
c2_unblocked = [i for i in ALL if c1_consensus(i) == "threw" and not res["C2"][i]["threw"]]
c2_regressed = [i for i in ALL if c1_consensus(i) == "cleared" and res["C2"][i]["threw"]]
if c2_unblocked:
    w(f"★ **{len(c2_unblocked)} node(s) threw under C1 (full prompt) but CLEARED under C2 (vocabulary line "
      f"removed): {', '.join(c2_unblocked)}.** Removing the 72-tag vocabulary line — the ONLY change from C1 to "
      f"C2 — is implicated in those refusals. Titles under C2:")
    for i in c2_unblocked:
        w(f"  - {i}: \"{esc(res['C2'][i]['title'])}\"")
else:
    w("**0 nodes cleared under C2 that threw under C1.** Removing the vocabulary line did not, on its own, "
      "unblock any node the full prompt refused. The vocabulary line is NOT implicated as a sole cause.")
w()
if c2_regressed:
    w(f"- (Opposite direction: {len(c2_regressed)} cleared under C1 but threw under C2 — {', '.join(c2_regressed)}.)")
w()

# ---------- 4. marginals C3-over-C2 and C4-over-C3 ----------
w("## 4. Marginal effects — C3 over C2, and C4 over C3 (stated separately)")
w()
c3_over_c2 = [i for i in ALL if res["C2"][i]["threw"] and not res["C3"][i]["threw"]]
c3_lost    = [i for i in ALL if not res["C2"][i]["threw"] and res["C3"][i]["threw"]]
c4_over_c3 = [i for i in ALL if res["C3"][i]["threw"] and not res["C4"][i]["threw"]]
c4_lost    = [i for i in ALL if not res["C3"][i]["threw"] and res["C4"][i]["threw"]]
w(f"**C3 over C2 (transformation frame added):** {len(c3_over_c2)} newly cleared "
  f"{'(' + ', '.join(c3_over_c2) + ')' if c3_over_c2 else ''}; {len(c3_lost)} newly threw "
  f"{'(' + ', '.join(c3_lost) + ')' if c3_lost else ''}.")
w()
w(f"**C4 over C3 (triple-quote fence added):** {len(c4_over_c3)} newly cleared "
  f"{'(' + ', '.join(c4_over_c3) + ')' if c4_over_c3 else ''}; {len(c4_lost)} newly threw "
  f"{'(' + ', '.join(c4_lost) + ')' if c4_lost else ''}.")
w()
w("_(Reported as two separate deltas per the brief — not collapsed into one 'the new prompt is better'.)_")
w()

# ---------- 5. 09C7E791 ----------
w("## 5. 09C7E791 (benign WWII control; threw input-side under every Round-7 cell)")
w()
w("| cell | C1a | C1b | C1c | C2 | C3 | C4 |")
w("|---|---|---|---|---|---|---|")
w("| 09C7E791 | " + " | ".join(cs(res[c]["09C7E791"]) for c in CELLS) + " |")
w()
cleared_in = [c for c in CELLS if not res[c]["09C7E791"]["threw"]]
if cleared_in:
    w(f"★ **09C7E791 CLEARS under: {', '.join(cleared_in)}.** "
      + (f"Title (first clearing cell {cleared_in[0]}): \"{esc(res[cleared_in[0]]['09C7E791']['title'])}\"." ))
else:
    w("**09C7E791 threw in EVERY cell** — no prompt surface tested here clears it. It remains a hard "
      "input-side refusal of benign content.")
w()

# ---------- 6. QUALITY for the 13 nodes that passed Round 7 (B3) ----------
b3_passed = [i for i in ALL if not b3[i]["threw"]]
w(f"## 6. Quality on the {len(b3_passed)} nodes that passed Round 7 (B3) — B3 vs C3 vs C4 (verbatim)")
w()
w("Clearance is not enough: a prompt that unblocks the refused set but produces vaguer summaries is a loss. "
  "Title + summary quoted verbatim; not characterized. (Reference B3 = Round 7 permissive title+summary; C3/C4 = "
  "Round 8 default title+summary.)")
w()
for i in b3_passed:
    w(f"### {i} — {setof[i]}")
    for label, r in [("B3 (R7)", b3[i]), ("C3", res["C3"][i]), ("C4", res["C4"][i])]:
        if r["threw"]:
            w(f"- **{label}:** THREW ({side(r)} {r['elapsedMs']}ms)")
        else:
            w(f"- **{label} title:** {esc(r['title'])}")
            w(f"- **{label} summary:** {esc(r['summary'])}")
    w()

with open(os.path.join(HD, "summary-round8.md"), "w") as f:
    f.write("\n".join(L) + "\n")
print("wrote summary-round8.md")
print(f"C1 unstable: {unstable}")
print(f"C1 consensus threw: {c1thr}")
print(f"C2 unblocked (threw C1, cleared C2): {c2_unblocked}")
print(f"C3 over C2 cleared: {c3_over_c2}; C4 over C3 cleared: {c4_over_c3}")
print(f"09C7E791 cleared in: {[c for c in CELLS if not res[c]['09C7E791']['threw']]}")
