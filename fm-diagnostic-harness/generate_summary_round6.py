#!/usr/bin/env python3
"""Generate summary-round6.md from results-A7*.json + results-A5.json + round6-nodes.json.

Round 6 = free-text stage 1 (no Generable), then Generable stage 2 over the model's
own prose. See Round6.swift. This is a Mac harness; per the standing rule the device
wins on prompt-behaviour verdicts, so nothing here is device-verified.
"""
import json, os, statistics

HD = os.path.dirname(os.path.abspath(__file__))
VARIANTS = ["A7a", "A7b", "A7c", "A7d"]
VLABEL = {"A7a": "P1 / G1-default", "A7b": "P1 / G2-permissive",
          "A7c": "P2 / G1-default", "A7d": "P2 / G2-permissive"}

def load(name):
    with open(os.path.join(HD, name)) as f:
        return json.load(f)

results = {v: load(f"results-{v}.json") for v in VARIANTS}
a5 = load("results-A5.json")
a5map = {r["nodeID"][:8].upper(): r for r in a5}
nodes = load("round6-nodes.json")
nodemeta = {n["id8"]: n for n in nodes}

# index results by (variant, id8)
by = {v: {r["id8"]: r for r in results[v]} for v in VARIANTS}
REFUSED = [n["id8"] for n in nodes if n["set"] == "REFUSED"]
CONTROL = [n["id8"] for n in nodes if n["set"] == "CONTROL"]

def cleared(r):
    """Cleared stage 1 = did not throw and not flagged as a soft-refusal."""
    return (not r["stage1Threw"]) and (not r["stage1SoftRefusal"])

def esc(s):
    return (s or "").replace("|", "\\|").replace("\n", " ").strip()

# ---- best-performing variant: most REFUSED cleared, tie-break fewer s2 throws, lower mean s1 latency
def score(v):
    rows = [by[v][i] for i in REFUSED]
    clr = sum(cleared(r) for r in rows)
    s2thr = sum(r["stage2Threw"] for r in rows if r["stage2Ran"])
    meanlat = statistics.mean([r["stage1Ms"] for r in rows]) if rows else 0
    return (clr, -s2thr, -meanlat)
best = max(VARIANTS, key=score)

L = []
def w(s=""): L.append(s)

w("# FM Diagnostic — Round 6: free-text stage 1, Generable stage 2")
w()
w("**What this tests.** Round 2's A5/A6 two-stage design used the *production* shape for "
  "stage 1 (`buildPrompt` + `@Generable SummaryFirstStage1`) — the shape that refuses. Round 6 "
  "replaces stage 1 with a genuinely different call: **free text** (`session.respond(to:)` "
  "returning `String`, no `@Generable`, chat register), then a **Generable stage 2** over the "
  "model's own prose. Four variants = 2 prompts × 2 guardrail settings "
  "(A7a=P1/G1, A7b=P1/G2, A7c=P2/G1, A7d=P2/G2).")
w()
w("- **P1 (bare):** the node's raw content text, nothing prepended.")
w("- **P2 (subject-direction):** the node text, a blank line, then exactly: "
  "`What are the core ideas at work here?`")
w("- **G1 = default guardrails; G2 = permissive** (`permissiveContentTransformations`).")
w("- **Stage 2** is Generable over the stage-1 STRING only (never raw node text), default "
  "guardrails, reusing the current production `@Guide` strings (see §1).")
w()
w("> This is a **Mac harness**. Apple DTS states refusals cannot be reliably caught outside "
  "guided generation, so the soft-refusal flag is a **reading aid, not a verdict**. The standing "
  "rule is that the **device wins** on prompt-behaviour verdicts — nothing here is device-verified.")
w()

# ---------- data-availability note ----------
w("## 0. Data-availability note (read first)")
w()
w("The 20 briefed node IDs were defined against the **May snapshot** that Rounds 2/5 ran on. "
  "**12 of the 20 have since been deleted** from every available corpus (live iCloud, "
  "`~/Developer/Corpus`, and the July `nodes.zip`). All 20 were nonetheless recovered at full "
  "fidelity and pinned into `round6-nodes.json` (audited, provenance below); nothing was "
  "fabricated or truncated:")
w()
w("| node | set | content source | len | note |")
w("|---|---|---|---:|---|")
for n in nodes:
    w(f"| {n['id8']} | {n['set']} | `{n['contentSource']}` | {n['contentLen']} | {esc(n['note'])} |")
w()
w("- `sec7c-round5` = the complete (non-truncated) *first-200-chars* text from `summary-round5.md` "
  "§7c — the exact input Round 5 refused on. `A5json-round2` = the complete `contentTruncated` from "
  "`results-A5.json` (all ≤135 chars, none truncated). `corpus-*` = full `extractContent` from a "
  "live corpus.")
w("- **9AF3AA17** was edited since May; the §7c May text was used for refusal fidelity. "
  "**8605E844 / D20112F1** had truncated §7c previews, so current corpus full content was used "
  "(8605E844 drops an `Episode premise: SpaceSex.` lead-in; D20112F1 matches modulo a newline/space join).")
w()

# ---------- STEP 0 verbatim ----------
w("## 1. Step 0 — SDK verification (verbatim)")
w()
w("Checked the `FoundationModels.swiftinterface` on the installed toolchain "
  "(`/Applications/Xcode.app` → `.../MacOSX.sdk/.../FoundationModels.swiftmodule/"
  "arm64e-apple-macos.swiftinterface`; **identical** in the Xcode-26.5-beta SDK). Built with "
  "`DEVELOPER_DIR=/Applications/Xcode.app` per the stable-toolchain rule.")
w()
w("**(a) Permissive guardrail option — EXISTS.** Exact spelling + init signature:")
w()
w("```swift")
w("extension FoundationModels.SystemLanguageModel {")
w("  public struct Guardrails : Swift.Sendable {")
w("    public static let `default`: FoundationModels.SystemLanguageModel.Guardrails")
w("    public static let permissiveContentTransformations: FoundationModels.SystemLanguageModel.Guardrails")
w("  }")
w("}")
w("// applied via SystemLanguageModel's initializer:")
w("convenience public init(useCase: FoundationModels.SystemLanguageModel.UseCase = .general, guardrails: FoundationModels.SystemLanguageModel.Guardrails = Guardrails.default)")
w("```")
w()
w("Usage in this harness: `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, "
  "then `LanguageModelSession(model:)`. Both G1 (default) and G2 (permissive) ran; the permissive "
  "model reported `isAvailable == true`.")
w()
w("**(b) Refusal case on `GenerationError` — exact spelling:**")
w()
w("```swift")
w("public enum GenerationError : Swift.Error, Foundation.LocalizedError {")
w("  // …")
w("  case guardrailViolation(FoundationModels.LanguageModelSession.GenerationError.Context)")
w("  case refusal(FoundationModels.LanguageModelSession.GenerationError.Refusal, FoundationModels.LanguageModelSession.GenerationError.Context)")
w("}")
w("```")
w()
w("(Enum is `LanguageModelSession.GenerationError`; the refusal case carries a `Refusal` + a "
  "`Context`.) The stage-2 `@Guide` strings reused verbatim from current app source: `title`/"
  "`summary` from `AIService.NodeAIResult`; **`tags` from `AIService.ProcessNodeResult`** — "
  "NodeAIResult in current source carries only title+summary. ⚠️ This production `tags` string "
  "differs from the one Round 2's A5 stage-2 used, so absolute tag sets are not 1:1 with Round 2 "
  "(title/summary strings are identical, so the §4 regression check is clean).")
w()

# ---------- per-variant aggregate ----------
w("## 2. Per-variant aggregate (REFUSED vs CONTROL)")
w()
def agg(v, ids):
    rows = [by[v][i] for i in ids]
    s1thr = sum(r["stage1Threw"] for r in rows)
    soft = sum(r["stage1SoftRefusal"] for r in rows)
    clr = sum(cleared(r) for r in rows)
    ran = [r for r in rows if r["stage2Ran"]]
    s2thr = sum(r["stage2Threw"] for r in ran)
    s1lat = statistics.mean([r["stage1Ms"] for r in rows]) if rows else 0
    s2lat = statistics.mean([r["stage2Ms"] for r in ran]) if ran else 0
    return s1thr, soft, clr, s2thr, len(ran), s1lat, s2lat
w("| variant | set | s1 threw | s1 soft-refusal | cleared s1 | s2 ran | s2 threw | mean s1 ms | mean s2 ms |")
w("|---|---|---:|---:|---:|---:|---:|---:|---:|")
for v in VARIANTS:
    for label, ids in [("REFUSED", REFUSED), ("CONTROL", CONTROL)]:
        s1thr, soft, clr, s2thr, ran, s1lat, s2lat = agg(v, ids)
        w(f"| {v} ({VLABEL[v]}) | {label} | {s1thr}/{len(ids)} | {soft}/{len(ids)} | "
          f"{clr}/{len(ids)} | {ran} | {s2thr} | {s1lat:.0f} | {s2lat:.0f} |")
w()
w(f"**Best-performing variant (most REFUSED cleared s1; tie-break fewer s2 throws, lower s1 "
  f"latency): `{best}` ({VLABEL[best]}).**")
w()
# ---- Signals: mechanical counts + pointers, NOT verdicts ----
def s1thrown(v, ids): return sum(by[v][i]["stage1Threw"] for i in ids)
def s2regress(v):
    out = []
    for i in CONTROL:
        r = by[v][i]
        s2ok = r["stage2Ran"] and not r["stage2Threw"] and r["stage2Title"].strip()
        a5ok = bool(a5map.get(i, {}).get("fmTitle", "").strip())
        if a5ok and not s2ok: out.append(i)
    return out
reg_best = s2regress(best)
w("**Signals (mechanical counts + pointers — NOT a verdict; the device wins):**")
w()
w(f"- **Permissive guardrail (G2) eliminates stage-1 throws.** REFUSED stage-1 throws by variant: "
  f"A7a={s1thrown('A7a',REFUSED)}/10, A7b={s1thrown('A7b',REFUSED)}/10, A7c={s1thrown('A7c',REFUSED)}/10, "
  f"A7d={s1thrown('A7d',REFUSED)}/10. Both permissive variants (A7b/A7d) threw 0.")
w(f"- **Default guardrails still block the most explicit inputs at stage 1** (fast ~130–230 ms "
  f"throws = input-side guardrail, not generation): A7a threw on {s1thrown('A7a',REFUSED)} REFUSED nodes.")
w(f"- **The Generable stage 2 is itself a refusal locus.** Under the best variant `{best}`, "
  f"{len(reg_best)} CONTROL node(s) that SUCCEEDED in Round 2 (A5) lost their stage-2 output "
  f"(stage-2 threw or produced nothing): {', '.join(reg_best) if reg_best else '(none)'}. "
  f"i.e. free-text stage 1 cleared, but guided generation over the prose still refused.")
w("- **The soft-refusal heuristic misses prose refusals** (as the brief anticipated — it is a "
  "reading aid, not a verdict). Example: **9AF3AA17** is marked ✓ (not flagged) under every "
  "variant, but its stage-1 prose is itself a refusal (\"I'm sorry, but as an LLM developed by "
  "Apple, I cannot…\") — see §5. Read the full text, not the flag.")
w()

# ---------- REFUSED per-node table ----------
w("## 3. REFUSED nodes — which variants cleared stage 1, and the resulting title")
w()
w("Legend: **✓** cleared (no throw, not soft-flagged) · **⚠** soft-refusal flag (heuristic) · "
  "**✗** stage-1 threw. Title = stage-2 title under the best variant "
  f"(`{best}`), or the first variant that cleared if best didn't.")
w()
w("> ⚠️ **✓ means \"the heuristic did not flag it,\" not \"a real answer.\"** A prose refusal that "
  "runs past ~200 chars and doesn't hit the keyword list reads as ✓ here (e.g. 9AF3AA17, whose "
  "stage-2 title below is literally the refusal). Cross-read every row against its full text in §5.")
w("")
w("| node | A7a | A7b | A7c | A7d | stage-2 title |")
w("|---|:--:|:--:|:--:|:--:|---|")
def cell(r):
    if r["stage1Threw"]: return "✗"
    return "✓" if not r["stage1SoftRefusal"] else "⚠"
for i in REFUSED:
    marks = []
    for v in VARIANTS:
        marks.append(cell(by[v][i]))
    # resulting title: prefer best variant's stage2 title, else first cleared
    title = ""
    order = [best] + [v for v in VARIANTS if v != best]
    for v in order:
        r = by[v][i]
        if r["stage2Ran"] and not r["stage2Threw"] and r["stage2Title"].strip():
            title = r["stage2Title"]; break
    w(f"| {i} | {marks[0]} | {marks[1]} | {marks[2]} | {marks[3]} | {esc(title)} |")
w()

# ---------- CONTROL regression vs A5 ----------
w("## 4. CONTROL nodes — Round 6 vs Round 2 (A5) regression check")
w()
w(f"Round 6 title/summary taken from the best variant (`{best}`) stage 2; Round 2 from "
  "`results-A5.json` (A5 = production-shape stage 1). A control that unblocks the refused ten "
  "but **degrades** the ten is a loss — watch for empty/garbled titles or summaries that lost "
  "specificity.")
w()
w("| node | R6 title | A5 title | R6 summary | A5 summary |")
w("|---|---|---|---|---|")
for i in CONTROL:
    r = by[best][i]
    a = a5map.get(i, {})
    r6t = esc(r["stage2Title"]) if r["stage2Ran"] and not r["stage2Threw"] else ("(s1 threw)" if r["stage1Threw"] else "(s2 skipped/threw)")
    r6s = esc(r["stage2Summary"]) if r["stage2Ran"] and not r["stage2Threw"] else ""
    w(f"| {i} | {r6t} | {esc(a.get('fmTitle',''))} | {r6s} | {esc(a.get('fmSummary',''))} |")
w()

# ---------- full stage1_raw for REFUSED under best variant ----------
w(f"## 5. Full stage-1 output for every REFUSED node — variant `{best}` ({VLABEL[best]})")
w()
w("Quoted in full (the primary artifact). Each block is the exact `stage1_raw`; the header notes "
  "the soft-refusal flag, latency, and the stage-2 title/tags it produced.")
w()
for i in REFUSED:
    r = by[best][i]
    meta = nodemeta[i]
    w(f"### {i} — {meta['set']} (source `{meta['contentSource']}`, {meta['contentLen']} ch input)")
    w()
    w(f"- **input (stage-1 prompt):** {'[P2] ' if r['promptVariant']=='P2' else ''}"
      f"`{esc(meta['content'])[:300]}`")
    flag = " · **soft-refusal flag**" if r["stage1SoftRefusal"] else ""
    thr = " · **STAGE-1 THREW**" if r["stage1Threw"] else ""
    w(f"- **stage-1:** {r['stage1Ms']} ms · {len(r['stage1Raw'])} chars{flag}{thr}")
    if r["stage1Threw"]:
        w(f"- **stage-1 error:** `{esc(r['stage1Error'])}`")
    if r["stage2Ran"]:
        if r["stage2Threw"]:
            w(f"- **stage-2:** THREW — `{esc(r['stage2Error'])}`")
        else:
            w(f"- **stage-2 title:** {esc(r['stage2Title'])}")
            w(f"- **stage-2 tags:** {', '.join(r['stage2Tags']) if r['stage2Tags'] else '(none)'}")
    else:
        w("- **stage-2:** skipped (stage 1 produced nothing)")
    w()
    w("```text")
    for line in (r["stage1Raw"] or "(empty)").splitlines() or ["(empty)"]:
        w(line)
    w("```")
    w()

with open(os.path.join(HD, "summary-round6.md"), "w") as f:
    f.write("\n".join(L) + "\n")
print(f"wrote summary-round6.md ({len(L)} lines). best variant = {best}")
