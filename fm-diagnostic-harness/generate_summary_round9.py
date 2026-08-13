#!/usr/bin/env python3
"""Generate summary-round9.md from results-D1..D4.json.

D1 baseline (String tags + vocab line) · D2 enum + line (A2 replica) · D3 enum, NO line
(headline) · D4 no tags, no line (floor). D3 vs D4 isolates the enum field: same prompt
(C2, no vocab line), only the tags field differs, so any throw delta is the enum's.
Mac harness; the device wins on prompt-behaviour verdicts. n=1 per cell.
"""
import json, os
HD = os.path.dirname(os.path.abspath(__file__))
def load(n):
    with open(os.path.join(HD, n)) as f: return json.load(f)
CELLS = ["D1", "D2", "D3", "D4"]
res = {c: {r["id8"]: r for r in load(f"results-{c}.json")} for c in CELLS}
nodes = load("round6-nodes.json")
ALL = [n["id8"] for n in nodes]; setof = {n["id8"]: n["set"] for n in nodes}
def side(r): return "-" if not r["threw"] else ("input" if r["elapsedMs"] < 500 else "gen")
def cs(r): return (f"THREW {side(r)} {r['elapsedMs']}ms") if r["threw"] else (f"ok {r['elapsedMs']}ms")
def esc(s): return (s or "").replace("|", "\\|").replace("\n", " ").strip()
def thrset(c): return [i for i in ALL if res[c][i]["threw"]]

L = []
def w(s=""): L.append(s)

w("# FM Diagnostic — Round 9: enum tags without the vocabulary line")
w()
w("**Question.** Round 8 implicated the 72-tag vocabulary LINE in `buildPrompt()`. Round 2's A2 used a "
  "`@Generable` enum (`VocabularyTag`) for tags — but carried the enum AND the prompt line together. Enum "
  "*without* the line had never been run. **Are `@Generable` enum case names scored by the input classifier the "
  "way prompt text is?** If NO, constrained decoding returns the vocabulary with zero classifier surface (D3 ≈ D4). "
  "If YES, the enum is not a fix (D3 throws more than D4).")
w()
w("- **D1** baseline — `buildPrompt` WITH vocab line; `tags:[String]` (Round 8 C1, re-run).")
w("- **D2** enum + line — WITH vocab line; `tags:[VocabularyTag]` (replicates Round 2 A2).")
w("- **D3** ★ enum, NO line — vocab line removed; `tags:[VocabularyTag]` (the untested headline).")
w("- **D4** no tags — vocab line removed, tags field removed; title+summary only (Round 8 C2 floor).")
w()
w("> **D3 vs D4 share the identical prompt (C2, no vocab line) — the ONLY difference is the enum tags field**, so "
  "any throw delta is attributable to the enum. Default guardrails everywhere; single-stage; raw content; same 20 "
  "nodes. Mac harness, **not device-verified**. ms: <500 = input-side (deterministic); multi-second = gen-side.")
w()

# ---------- 1. locale ----------
w("## 1. Step 0 — locale (forum 802921: guardrails over-trigger for some locales)")
w()
w("- **AppleLocale = `en_US`.** AppleLanguages = `(\"en-US\", \"es-US\")` (primary `en-US`). "
  "Siri / Apple-Intelligence Session Language = `en-US`. `Locale.current` in the harness process printed "
  "`en_US` (see run-round9.log header).")
w("- **Already en_US → the non-en_US second pass is skipped per the brief.** The locale over-trigger bug is not "
  "in play for this machine; all cells below ran under en_US.")
w()

# ---------- 2. per-node table ----------
w("## 2. Per-node outcomes — D1 / D2 / D3 / D4")
w()
w("| node | set | D1 (str+line) | D2 (enum+line) | D3 (enum, no line) | D4 (no tags) |")
w("|---|---|---|---|---|---|")
for i in ALL:
    w(f"| {i} | {setof[i]} | {cs(res['D1'][i])} | {cs(res['D2'][i])} | {cs(res['D3'][i])} | {cs(res['D4'][i])} |")
w()
for c in CELLS:
    t = thrset(c)
    w(f"- **{c} threw {len(t)}/20** {'(' + ', '.join(t) + ')' if t else ''}.")
w()

# ---------- 3. HEADLINE: D3 vs D4 ----------
w("## 3. [HEADLINE] D3 (enum, no line) vs D4 (no tags, no line) — are enum case names classifier surface?")
w()
d3, d4 = thrset("D3"), thrset("D4")
d3_only = [i for i in ALL if res["D3"][i]["threw"] and not res["D4"][i]["threw"]]
d4_only = [i for i in ALL if res["D4"][i]["threw"] and not res["D3"][i]["threw"]]
w(f"D3 threw {len(d3)}/20; D4 threw {len(d4)}/20. Same prompt; only the enum tags field differs.")
w()
if len(d3) > len(d4) and d3_only:
    w(f"★ **YES — enum case names ARE contributing classifier surface.** D3 threw on "
      f"{len(d3_only)} node(s) that D4 cleared ({', '.join(d3_only)}); the only change is adding the "
      f"`VocabularyTag` enum, so those extra refusals are attributable to the enum's 72 case names. The enum is "
      f"**not** a free way to get the vocabulary back.")
elif set(d3) == set(d4):
    w("★ **NO — enum case names are NOT contributing classifier surface.** D3 and D4 threw on the **exact same "
      "node set** despite D3 carrying the full 72-case `VocabularyTag` enum. Constrained decoding returns the "
      "vocabulary with **zero added classifier surface** — the enum is a free win over the prompt line.")
elif len(d3) <= len(d4):
    w(f"★ **NO (enum ≤ floor).** D3 threw {len(d3)} vs D4 {len(d4)} — the enum did not add refusals "
      f"(D3-only: {d3_only or 'none'}; D4-only: {d4_only or 'none'}). Enum case names are not acting as classifier "
      f"surface here.")
else:
    w(f"**MIXED / INCONCLUSIVE.** D3-only throws: {d3_only or 'none'}; D4-only throws: {d4_only or 'none'}. With "
      f"n=1 per cell and generation-side variability this does not cleanly separate — note the ms/side per node above.")
w()

# ---------- 4. D3 vs D1 (production today) ----------
w("## 4. D3 (enum, no line) vs D1 (production-style: String tags + vocab line)")
w()
gained = [i for i in ALL if res["D1"][i]["threw"] and not res["D3"][i]["threw"]]
lost   = [i for i in ALL if not res["D1"][i]["threw"] and res["D3"][i]["threw"]]
w(f"D1 threw {len(thrset('D1'))}/20; D3 threw {len(thrset('D3'))}/20.")
w(f"- **Gained (threw in D1, cleared in D3): {len(gained)}** {'(' + ', '.join(gained) + ')' if gained else ''}.")
w(f"- **Lost (cleared in D1, threw in D3): {len(lost)}** {'(' + ', '.join(lost) + ')' if lost else ''}.")
w(f"- **Net: {len(gained) - len(lost):+d} nodes** vs production-style D1.")
w()

# ---------- 5. tag quality D1 (String) vs D2/D3 (enum) ----------
w("## 5. Tag quality — String tags (D1) vs enum tags (D2/D3), verbatim")
w()
w("Does forcing selection from the fixed enum produce worse tags? Tags quoted verbatim, not characterized. "
  "★ Flag = D1 (free String) returned NO tags but the enum cell returned some — i.e. the enum forced a pick.")
w()
w("| node | D1 String tags | D2 enum tags | D3 enum tags | enum forced? |")
w("|---|---|---|---|---|")
for i in ALL:
    d1t = res["D1"][i]["tags"] if not res["D1"][i]["threw"] else None
    d2t = res["D2"][i]["tags"] if not res["D2"][i]["threw"] else None
    d3t = res["D3"][i]["tags"] if not res["D3"][i]["threw"] else None
    def fmt(t): return "(threw)" if t is None else (", ".join(t) if t else "(empty)")
    forced = "★ yes" if (d1t == [] and ((d2t and len(d2t) > 0) or (d3t and len(d3t) > 0))) else ""
    w(f"| {i} | {esc(fmt(d1t))} | {esc(fmt(d2t))} | {esc(fmt(d3t))} | {forced} |")
w()

# ---------- 6. 09C7E791 ----------
w("## 6. 09C7E791 (benign WWII control) — does it clear in D3?")
w()
w("| cell | D1 | D2 | D3 | D4 |")
w("|---|---|---|---|---|")
w("| 09C7E791 | " + " | ".join(cs(res[c]["09C7E791"]) for c in CELLS) + " |")
w()
r = res["D3"]["09C7E791"]
if not r["threw"]:
    w(f"★ **YES — 09C7E791 CLEARS in D3** ({r['elapsedMs']}ms). title: \"{esc(r['title'])}\"; "
      f"tags: {', '.join(r['tags']) if r['tags'] else '(none)'}.")
else:
    w(f"**NO — 09C7E791 threw in D3** ({side(r)} {r['elapsedMs']}ms). "
      + ("It cleared in D4 (no tags), so the enum re-blocks it." if not res["D4"]["09C7E791"]["threw"]
         else "It also threw in D4 — removing the vocab line alone does not clear it under the enum."))
w()

with open(os.path.join(HD, "summary-round9.md"), "w") as f:
    f.write("\n".join(L) + "\n")
print("wrote summary-round9.md")
for c in CELLS: print(f"{c} threw {len(thrset(c))}/20: {thrset(c)}")
print(f"D3-only vs D4: {d3_only}; D4-only vs D3: {d4_only}")
print(f"09C7E791 D3: {'cleared' if not res['D3']['09C7E791']['threw'] else 'threw'}")
