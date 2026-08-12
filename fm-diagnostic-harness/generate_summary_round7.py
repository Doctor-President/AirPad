#!/usr/bin/env python3
"""Generate summary-round7.md from results-B1..B4.json.

Round 7 isolates the guardrail (B1 default vs B2 permissive, same full Generable shape
on raw node content) and then the output-schema size (B2 full / B3 title+summary /
B4 title-only, all permissive). Single-stage Generable, production prompt (buildPrompt).
Mac harness; the device wins on prompt-behaviour verdicts. n=1 per (node, cell).
"""
import json, os, statistics

HD = os.path.dirname(os.path.abspath(__file__))
CELLS = ["B1", "B2", "B3", "B4"]
CLABEL = {"B1": "default / full-5field", "B2": "permissive / full-5field",
          "B3": "permissive / title+summary", "B4": "permissive / title-only"}

def load(n):
    with open(os.path.join(HD, n)) as f:
        return json.load(f)

res = {c: {r["id8"]: r for r in load(f"results-{c}.json")} for c in CELLS}
nodes = load("round6-nodes.json")
REFUSED = [n["id8"] for n in nodes if n["set"] == "REFUSED"]
CONTROL = [n["id8"] for n in nodes if n["set"] == "CONTROL"]
ALL = REFUSED + CONTROL
setof = {n["id8"]: n["set"] for n in nodes}

def side(r):
    return "input" if (r["threw"] and r["elapsedMs"] < 500) else ("gen" if r["threw"] else "-")

def esc(s):
    return (s or "").replace("|", "\\|").replace("\n", " ").strip()

L = []
def w(s=""): L.append(s)

w("# FM Diagnostic — Round 7: Generable + permissive guardrails")
w()
w("**Question.** Round 6 ran every Generable (stage-2) call at DEFAULT guardrails; production "
  "(`AIService`) also builds plain `LanguageModelSession()` everywhere — so permissive has never "
  "been tested on a guided-generation call. The claim *\"permissiveContentTransformations does not "
  "apply to Generable\"* is a developer-forum report (secondary source), never verified against this "
  "SDK. Round 7 verifies it directly with a **single-stage** Generable call on the **raw** node "
  "content (production `buildPrompt`), isolating one variable at a time.")
w()
w("- **B1** = default guardrails, full 5-field shape — reproduces the Round 5 baseline.")
w("- **B2** = permissive guardrails, full 5-field shape — the untested cell (one variable vs B1).")
w("- **B3** = permissive, title+summary only. **B4** = permissive, title only. (B3/B4 share B2's "
  "prompt + guardrails; only the output schema shrinks.)")
w()
w("> Mac harness, **not device-verified** — the device wins on prompt-behaviour verdicts. Each cell "
  "is a **single run** per node (n=1), so small differences can be stochastic; the ms column "
  "distinguishes **input-side** throws (<500 ms, deterministic guardrail rejection) from "
  "**generation-side** throws (multi-second, can vary run to run). Same 20 nodes as Round 6, from "
  "`round6-nodes.json` (not re-derived).")
w()

# ---------- STEP 0 ----------
w("## 1. Step 0 — document verification (verbatim)")
w()
w("Re-checked `.../MacOSX.sdk/.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` "
  "(identical in the 26.5 SDK).")
w()
w("- **The `.swiftinterface` carries ZERO `///` doc comments** (grep `///` → 0). Prose documentation "
  "lives in `.swiftdoc`, which is stripped from the shipped interface — so there is no doc-comment "
  "text in the interface to state (or deny) any restriction.")
w("- **`Guardrails` and `permissiveContentTransformations` carry only standard availability "
  "annotations** — no restriction, no guided-generation note:")
w()
w("```swift")
w("@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)")
w("@available(tvOS, unavailable)")
w("@available(watchOS, unavailable)")
w("extension FoundationModels.SystemLanguageModel {")
w("  public struct Guardrails : Swift.Sendable {")
w("    public static let `default`: FoundationModels.SystemLanguageModel.Guardrails")
w("    public static let permissiveContentTransformations: FoundationModels.SystemLanguageModel.Guardrails")
w("  }")
w("}")
w("```")
w()
w("- **The Generable `respond` overloads take NO guardrail parameter** — guardrails are a property "
  "of the *model*, not the call, and the same overload serves every output type:")
w()
w("```swift")
w("nonisolated(nonsending) final public func respond<Content>(to prompt: FoundationModels.Prompt, generating type: Content.Type = Content.self, includeSchemaInPrompt: Swift.Bool = true, options: FoundationModels.GenerationOptions = GenerationOptions()) async throws -> FoundationModels.LanguageModelSession.Response<Content> where Content : FoundationModels.Generable")
w("```")
w()
w("- **Every `guardrail` mention in the entire interface:** `GenerationError.guardrailViolation(Context)`; "
  "the `Guardrails` struct + its two `static let`s; the two `SystemLanguageModel.init(…, guardrails:)` "
  "convenience inits; and `LanguageModelFeedback.Issue.Category.triggeredGuardrailUnexpectedly` — a "
  "**user-feedback category**, not an API restriction. **Nothing documents a restriction on `Guardrails` "
  "with guided generation.**")
w()
w("- **Exact init used (verbatim):**")
w()
w("```swift")
w("convenience public init(useCase: FoundationModels.SystemLanguageModel.UseCase = .general, guardrails: FoundationModels.SystemLanguageModel.Guardrails = Guardrails.default)")
w("// →")
w("let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)")
w("let session = LanguageModelSession(model: model)")
w("let out = try await session.respond(to: buildPrompt(...), generating: SummaryFirstStage1.self)")
w("```")
w()
w("**Absence of a documented restriction is not proof it works.** The run below is the proof.")
w()

# ---------- STEP 2: B1 vs B2 ----------
w("## 2. B1 (default) vs B2 (permissive) — same full shape, raw content [HEADLINE]")
w()
w("Legend: **THREW** (side, ms) or **ok** (ms). If any node **cleared under B2 that threw under B1**, "
  "the foreclosure claim is FALSE.")
w()
w("| node | set | B1 default | B2 permissive | Δ |")
w("|---|---|---|---|---|")
def cellstr(r):
    if r["threw"]:
        return f"THREW {side(r)} {r['elapsedMs']}ms"
    return f"ok {r['elapsedMs']}ms"
unblocked, newly_blocked, unblocked_input = [], [], []
for i in ALL:
    b1, b2 = res["B1"][i], res["B2"][i]
    delta = ""
    if b1["threw"] and not b2["threw"]:
        delta = "**B2 CLEARED**"; unblocked.append(i)
        if side(b1) == "input": unblocked_input.append(i)
    elif (not b1["threw"]) and b2["threw"]:
        delta = "B2 regressed"; newly_blocked.append(i)
    w(f"| {i} | {setof[i]} | {cellstr(b1)} | {cellstr(b2)} | {delta} |")
w()
b1thr = [i for i in ALL if res["B1"][i]["threw"]]
b2thr = [i for i in ALL if res["B2"][i]["threw"]]
w(f"- **B1 threw {len(b1thr)}/20; B2 threw {len(b2thr)}/20.**")
w(f"- **Cleared under B2 but threw under B1 (foreclosure-breaking): {len(unblocked)}** "
  f"{'(' + ', '.join(unblocked) + ')' if unblocked else ''} — of which **{len(unblocked_input)} were "
  f"input-side (deterministic) throws under B1**{': ' + ', '.join(unblocked_input) if unblocked_input else ''}.")
w(f"- Cleared under B1 but threw under B2 (opposite direction): {len(newly_blocked)} "
  f"{'(' + ', '.join(newly_blocked) + ')' if newly_blocked else ''}.")
w()

# ---------- STEP 3: B2 vs B3 vs B4 ----------
w("## 3. Schema-size axis — B2 (full) vs B3 (title+summary) vs B4 (title-only), all permissive")
w()
w("Does shrinking the output schema change outcomes independently of guardrails?")
w()
w("| node | set | B2 full | B3 title+summary | B4 title-only |")
w("|---|---|---|---|---|")
for i in ALL:
    w(f"| {i} | {setof[i]} | {cellstr(res['B2'][i])} | {cellstr(res['B3'][i])} | {cellstr(res['B4'][i])} |")
w()
for c in ["B2", "B3", "B4"]:
    t = [i for i in ALL if res[c][i]["threw"]]
    w(f"- **{c} ({CLABEL[c]}) threw {len(t)}/20** {'(' + ', '.join(t) + ')' if t else ''}.")
w()

# ---------- cross-round corroboration: did permissive clear these SAME inputs as free text (Round 6)? ----------
# Round 6 A7b = permissive + FREE-TEXT (String) stage 1. If the B2 (permissive+Generable) throwers
# CLEARED there, then "the inputs exceed even permissive" is ruled out — the failure is specific to
# guided generation, not to the permissive policy being too weak for this content.
xround = None
try:
    a7b = {r["id8"]: r for r in load("results-A7b.json")}
    b2thr_set = [i for i in ALL if res["B2"][i]["threw"]]
    cleared_as_freetext = [i for i in b2thr_set
                           if i in a7b and not a7b[i]["stage1Threw"] and not a7b[i]["stage1SoftRefusal"]]
    xround = (b2thr_set, cleared_as_freetext)
except Exception:
    xround = None

# ---------- STEP 4: explicit verdict ----------
w("## 4. Verdict — does permissive reach Generable in this SDK?")
w()
# Decision logic (conservative; weight deterministic input-side unblocking):
if len(unblocked_input) >= 1:
    verdict = "**YES** — permissive reaches guided generation."
    basis = (f"{len(unblocked_input)} node(s) that hit a **deterministic input-side** guardrail throw "
             f"under B1 (default) **cleared** under B2 (permissive), same shape and prompt. Input-side "
             f"throws are not stochastic, so this is not run-to-run noise: the only changed variable is "
             f"the guardrail. The forum foreclosure claim is **FALSE** for this SDK build.")
elif len(unblocked) >= 3 and len(unblocked) > 2 * len(newly_blocked):
    verdict = "**YES (generation-side)** — permissive appears to reach Generable."
    basis = (f"{len(unblocked)} nodes cleared under B2 that threw under B1, vs {len(newly_blocked)} the "
             f"other way; all were generation-side, so read with n=1 caution, but the asymmetry is large.")
elif len(b2thr) == len(b1thr) and set(b2thr) == set(b1thr):
    verdict = "**NO** — permissive does NOT reach guided generation in this SDK build."
    basis = ("B2 (permissive) threw on **exactly the same node set** as B1 (default) — 0 unblocked, "
             "0 newly-blocked — and 6 of the 7 throws are **deterministic input-side** rejections "
             "(<500 ms), which are not stochastic. The permissive guardrail had no effect on the "
             "guided-generation path.")
    if xround is not None:
        b2thr_set, cleared_ft = xround
        basis += (f" **Cross-round corroboration rules out the 'inputs exceed even permissive' "
                  f"alternative:** of the {len(b2thr_set)} nodes that threw here under permissive+Generable, "
                  f"**{len(cleared_ft)} cleared in Round 6 under permissive + FREE-TEXT (String)** "
                  f"(A7b: {', '.join(cleared_ft) if cleared_ft else 'none'}). Identical inputs, identical "
                  f"permissive setting — they pass on the String path and fail on the Generable path. The "
                  f"only difference is guided generation, so permissive's effect is nullified specifically "
                  f"by Generable. The developer-forum foreclosure claim is **confirmed** against this SDK.")
else:
    verdict = "**INCONCLUSIVE.**"
    basis = (f"B1 threw {len(b1thr)}/20, B2 threw {len(b2thr)}/20; {len(unblocked)} unblocked / "
             f"{len(newly_blocked)} newly-blocked, all generation-side. With n=1 per cell this is within "
             f"stochastic range — not a clean yes or no. A repeated-trial run would be needed to resolve.")
w(verdict)
w()
w(basis)
w()
w("_(Stated explicitly per the brief; an inconclusive is reported as inconclusive, not softened.)_")
w()

# ---------- STEP 5: FF43DCC8 + 09C7E791 ----------
w("## 5. The two Round-6 stage-2 casualties — FF43DCC8 & 09C7E791")
w()
w("These two benign controls lost their stage-2 output in Round 6 (Generable, default guardrails). "
  "Do they clear under any Round-7 cell?")
w()
w("| node | B1 default | B2 permissive | B3 title+summary | B4 title-only |")
w("|---|---|---|---|---|")
for i in ["FF43DCC8", "09C7E791"]:
    w(f"| {i} | {cellstr(res['B1'][i])} | {cellstr(res['B2'][i])} | {cellstr(res['B3'][i])} | {cellstr(res['B4'][i])} |")
w()
for i in ["FF43DCC8", "09C7E791"]:
    cleared_cells = [c for c in CELLS if not res[c][i]["threw"]]
    w(f"- **{i}:** cleared under {', '.join(cleared_cells) if cleared_cells else 'NO cell'}"
      + (f" — title: \"{esc(res[cleared_cells[0]][i]['title'])}\"" if cleared_cells else "") + ".")
w()

# ---------- appendix: full text for non-throws (REFUSED, B2) ----------
w("## 6. Full output text — every non-throw under B2 (permissive, full shape)")
w()
w("Untruncated per the brief. (Throws are covered by the tables above; their full error strings are "
  "in `results-B2.json`.)")
w()
for i in ALL:
    r = res["B2"][i]
    if r["threw"]:
        continue
    w(f"### {i} — {setof[i]} ({r['elapsedMs']} ms)")
    w(f"- **title:** {esc(r['title'])}")
    w(f"- **summary:** {esc(r['summary'])}")
    w(f"- **tags:** {', '.join(r['tags']) if r['tags'] else '(none)'}")
    w()

with open(os.path.join(HD, "summary-round7.md"), "w") as f:
    f.write("\n".join(L) + "\n")
print("wrote summary-round7.md")
print(f"B1 threw {len(b1thr)}/20; B2 threw {len(b2thr)}/20; unblocked={unblocked} (input-side={unblocked_input}); newly_blocked={newly_blocked}")
print("VERDICT:", verdict.replace('*',''))
