# FM Diagnostic — Round 7: Generable + permissive guardrails

**Question.** Round 6 ran every Generable (stage-2) call at DEFAULT guardrails; production (`AIService`) also builds plain `LanguageModelSession()` everywhere — so permissive has never been tested on a guided-generation call. The claim *"permissiveContentTransformations does not apply to Generable"* is a developer-forum report (secondary source), never verified against this SDK. Round 7 verifies it directly with a **single-stage** Generable call on the **raw** node content (production `buildPrompt`), isolating one variable at a time.

- **B1** = default guardrails, full 5-field shape — reproduces the Round 5 baseline.
- **B2** = permissive guardrails, full 5-field shape — the untested cell (one variable vs B1).
- **B3** = permissive, title+summary only. **B4** = permissive, title only. (B3/B4 share B2's prompt + guardrails; only the output schema shrinks.)

> Mac harness, **not device-verified** — the device wins on prompt-behaviour verdicts. Each cell is a **single run** per node (n=1), so small differences can be stochastic; the ms column distinguishes **input-side** throws (<500 ms, deterministic guardrail rejection) from **generation-side** throws (multi-second, can vary run to run). Same 20 nodes as Round 6, from `round6-nodes.json` (not re-derived).

## 1. Step 0 — document verification (verbatim)

Re-checked `.../MacOSX.sdk/.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` (identical in the 26.5 SDK).

- **The `.swiftinterface` carries ZERO `///` doc comments** (grep `///` → 0). Prose documentation lives in `.swiftdoc`, which is stripped from the shipped interface — so there is no doc-comment text in the interface to state (or deny) any restriction.
- **`Guardrails` and `permissiveContentTransformations` carry only standard availability annotations** — no restriction, no guided-generation note:

```swift
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension FoundationModels.SystemLanguageModel {
  public struct Guardrails : Swift.Sendable {
    public static let `default`: FoundationModels.SystemLanguageModel.Guardrails
    public static let permissiveContentTransformations: FoundationModels.SystemLanguageModel.Guardrails
  }
}
```

- **The Generable `respond` overloads take NO guardrail parameter** — guardrails are a property of the *model*, not the call, and the same overload serves every output type:

```swift
nonisolated(nonsending) final public func respond<Content>(to prompt: FoundationModels.Prompt, generating type: Content.Type = Content.self, includeSchemaInPrompt: Swift.Bool = true, options: FoundationModels.GenerationOptions = GenerationOptions()) async throws -> FoundationModels.LanguageModelSession.Response<Content> where Content : FoundationModels.Generable
```

- **Every `guardrail` mention in the entire interface:** `GenerationError.guardrailViolation(Context)`; the `Guardrails` struct + its two `static let`s; the two `SystemLanguageModel.init(…, guardrails:)` convenience inits; and `LanguageModelFeedback.Issue.Category.triggeredGuardrailUnexpectedly` — a **user-feedback category**, not an API restriction. **Nothing documents a restriction on `Guardrails` with guided generation.**

- **Exact init used (verbatim):**

```swift
convenience public init(useCase: FoundationModels.SystemLanguageModel.UseCase = .general, guardrails: FoundationModels.SystemLanguageModel.Guardrails = Guardrails.default)
// →
let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
let session = LanguageModelSession(model: model)
let out = try await session.respond(to: buildPrompt(...), generating: SummaryFirstStage1.self)
```

**Absence of a documented restriction is not proof it works.** The run below is the proof.

## 2. B1 (default) vs B2 (permissive) — same full shape, raw content [HEADLINE]

Legend: **THREW** (side, ms) or **ok** (ms). If any node **cleared under B2 that threw under B1**, the foreclosure claim is FALSE.

| node | set | B1 default | B2 permissive | Δ |
|---|---|---|---|---|
| 1130789A | REFUSED | THREW gen 663ms | THREW input 170ms |  |
| 17B0552D | REFUSED | THREW input 244ms | THREW input 237ms |  |
| 37B4904F | REFUSED | ok 14741ms | ok 5145ms |  |
| 8605E844 | REFUSED | THREW input 401ms | THREW input 376ms |  |
| 9AF3AA17 | REFUSED | ok 8557ms | ok 5477ms |  |
| 9F74032F | REFUSED | THREW input 255ms | THREW input 244ms |  |
| BF9595C3 | REFUSED | THREW input 245ms | THREW input 244ms |  |
| D20112F1 | REFUSED | ok 11047ms | ok 8335ms |  |
| E7BCE684 | REFUSED | THREW input 257ms | THREW input 247ms |  |
| FF0C11DE | REFUSED | ok 8378ms | ok 8363ms |  |
| C57169F2 | CONTROL | ok 8598ms | ok 5413ms |  |
| 70A66523 | CONTROL | ok 4756ms | ok 4794ms |  |
| 0A0DB1DA | CONTROL | ok 8250ms | ok 8405ms |  |
| 1E9C4DEF | CONTROL | ok 8717ms | ok 8552ms |  |
| 3B5584B8 | CONTROL | ok 6103ms | ok 9100ms |  |
| 09C7E791 | CONTROL | THREW input 295ms | THREW input 295ms |  |
| DEA2B9DB | CONTROL | ok 5234ms | ok 5578ms |  |
| 7735A62F | CONTROL | ok 4793ms | ok 5033ms |  |
| 4B5E9285 | CONTROL | ok 5266ms | ok 5317ms |  |
| FF43DCC8 | CONTROL | ok 5081ms | ok 5424ms |  |

- **B1 threw 7/20; B2 threw 7/20.**
- **Cleared under B2 but threw under B1 (foreclosure-breaking): 0**  — of which **0 were input-side (deterministic) throws under B1**.
- Cleared under B1 but threw under B2 (opposite direction): 0 .

## 3. Schema-size axis — B2 (full) vs B3 (title+summary) vs B4 (title-only), all permissive

Does shrinking the output schema change outcomes independently of guardrails?

| node | set | B2 full | B3 title+summary | B4 title-only |
|---|---|---|---|---|
| 1130789A | REFUSED | THREW input 170ms | THREW input 181ms | THREW input 184ms |
| 17B0552D | REFUSED | THREW input 237ms | THREW input 235ms | THREW input 245ms |
| 37B4904F | REFUSED | ok 5145ms | ok 8038ms | ok 3863ms |
| 8605E844 | REFUSED | THREW input 376ms | THREW input 381ms | THREW input 382ms |
| 9AF3AA17 | REFUSED | ok 5477ms | ok 1657ms | ok 4048ms |
| 9F74032F | REFUSED | THREW input 244ms | THREW input 252ms | THREW input 243ms |
| BF9595C3 | REFUSED | THREW input 244ms | THREW input 256ms | THREW input 250ms |
| D20112F1 | REFUSED | ok 8335ms | ok 1181ms | ok 3887ms |
| E7BCE684 | REFUSED | THREW input 247ms | THREW input 232ms | THREW input 238ms |
| FF0C11DE | REFUSED | ok 8363ms | ok 4925ms | ok 4059ms |
| C57169F2 | CONTROL | ok 5413ms | ok 4997ms | ok 3886ms |
| 70A66523 | CONTROL | ok 4794ms | ok 4332ms | ok 3743ms |
| 0A0DB1DA | CONTROL | ok 8405ms | ok 7629ms | THREW gen 3680ms |
| 1E9C4DEF | CONTROL | ok 8552ms | ok 4691ms | ok 3661ms |
| 3B5584B8 | CONTROL | ok 9100ms | ok 5433ms | ok 3948ms |
| 09C7E791 | CONTROL | THREW input 295ms | THREW input 302ms | THREW input 291ms |
| DEA2B9DB | CONTROL | ok 5578ms | ok 4990ms | ok 4031ms |
| 7735A62F | CONTROL | ok 5033ms | ok 4501ms | ok 3828ms |
| 4B5E9285 | CONTROL | ok 5317ms | ok 4667ms | ok 3960ms |
| FF43DCC8 | CONTROL | ok 5424ms | ok 4465ms | ok 3921ms |

- **B2 (permissive / full-5field) threw 7/20** (1130789A, 17B0552D, 8605E844, 9F74032F, BF9595C3, E7BCE684, 09C7E791).
- **B3 (permissive / title+summary) threw 7/20** (1130789A, 17B0552D, 8605E844, 9F74032F, BF9595C3, E7BCE684, 09C7E791).
- **B4 (permissive / title-only) threw 8/20** (1130789A, 17B0552D, 8605E844, 9F74032F, BF9595C3, E7BCE684, 0A0DB1DA, 09C7E791).

## 4. Verdict — does permissive reach Generable in this SDK?

**NO** — permissive does NOT reach guided generation in this SDK build.

B2 (permissive) threw on **exactly the same node set** as B1 (default) — 0 unblocked, 0 newly-blocked — and 6 of the 7 throws are **deterministic input-side** rejections (<500 ms), which are not stochastic. The permissive guardrail had no effect on the guided-generation path. **Cross-round corroboration rules out the 'inputs exceed even permissive' alternative:** of the 7 nodes that threw here under permissive+Generable, **5 cleared in Round 6 under permissive + FREE-TEXT (String)** (A7b: 1130789A, 17B0552D, 8605E844, 9F74032F, E7BCE684). Identical inputs, identical permissive setting — they pass on the String path and fail on the Generable path. The only difference is guided generation, so permissive's effect is nullified specifically by Generable. The developer-forum foreclosure claim is **confirmed** against this SDK.

_(Stated explicitly per the brief; an inconclusive is reported as inconclusive, not softened.)_

## 5. The two Round-6 stage-2 casualties — FF43DCC8 & 09C7E791

These two benign controls lost their stage-2 output in Round 6 (Generable, default guardrails). Do they clear under any Round-7 cell?

| node | B1 default | B2 permissive | B3 title+summary | B4 title-only |
|---|---|---|---|---|
| FF43DCC8 | ok 5081ms | ok 5424ms | ok 4465ms | ok 3921ms |
| 09C7E791 | THREW input 295ms | THREW input 295ms | THREW input 302ms | THREW input 291ms |

- **FF43DCC8:** cleared under B1, B2, B3, B4 — title: "Queerness as Self-Expression".
- **09C7E791:** cleared under NO cell.

## 6. Full output text — every non-throw under B2 (permissive, full shape)

Untruncated per the brief. (Throws are covered by the tables above; their full error strings are in `results-B2.json`.)

### 37B4904F — REFUSED (5145 ms)
- **title:** Exploring the Origins of 'Honky'
- **summary:** Investigating the etymology of the term 'honky' to understand its historical and cultural implications.
- **tags:** Etymology, Historical Revisionism, Cultural Studies

### 9AF3AA17 — REFUSED (5477 ms)
- **title:** Attention-Grabbing Comedy
- **summary:** An episode premise that humorously explores the allure of attention, using a relatable and unconventional scenario.
- **tags:** Comedy, Attention, Humor

### D20112F1 — REFUSED (8335 ms)
- **title:** Ideas and Privacy
- **summary:** The idea emphasizes the importance of individual privacy in protecting personal ideas from external invasion.
- **tags:** Privacy, Conceptual, Control, Ownership

### FF0C11DE — REFUSED (8363 ms)
- **title:** Tom McJazz's Iconoclastic Videos
- **summary:** Tom McJazz creates videos reacting to things he dislikes, blending humor, critique, and creativity.
- **tags:** Art, Comedy, Conceptual

### C57169F2 — CONTROL (5413 ms)
- **title:** Diet Coke and High Achievement
- **summary:** Exploring the psychological and sociological factors behind the popularity of Diet Coke among high-achieving individuals in Washington DC.
- **tags:** Psychology, Sociology, Washington DC

### 70A66523 — CONTROL (4794 ms)
- **title:** Geometry
- **summary:** Explores the concept of angles and their roles in different contexts.
- **tags:** Geometry

### 0A0DB1DA — CONTROL (8405 ms)
- **title:** Hole to China Episode
- **summary:** An episode of a fictional show exploring the concept of a hole leading to China.
- **tags:** Conceptual, Travel, Story

### 1E9C4DEF — CONTROL (8552 ms)
- **title:** Action Button Reveal
- **summary:** An innovative reveal feature in an app allows users to capture and access items from the world without opening the app, emphasizing convenience and accessibility.
- **tags:** Design, Technology

### 3B5584B8 — CONTROL (9100 ms)
- **title:** The Complexity of Good and Evil in Modern Times
- **summary:** Examines the interplay between light and darkness in contemporary society, questioning whether morality is always black-and-white or if it is influenced by external factors.
- **tags:** Light vs darkness, Morality, Complexity

### DEA2B9DB — CONTROL (5578 ms)
- **title:** Breakfast Reimagined
- **summary:** Explores the historical shift from supper and dinner to breakfast, questioning its origins and the influence of the food industry.
- **tags:** Breakfast, Nutrition, History

### 7735A62F — CONTROL (5033 ms)
- **title:** Plum Tomato Recipe
- **summary:** A simple recipe for using 1 1/2 pounds of plum tomatoes.
- **tags:** Recipe

### 4B5E9285 — CONTROL (5317 ms)
- **title:** AirPad as a Conceptual Layer
- **summary:** AirPad is not just an app; it represents a deeper, conceptual layer that extends beyond its functional capabilities.
- **tags:** Conceptual, Design

### FF43DCC8 — CONTROL (5424 ms)
- **title:** Queerness as Self-Determination
- **summary:** Queerness embodies living life on one's own terms, emphasizing personal freedom and autonomy.
- **tags:** Conceptual, Self-Expression, Identity, Freedom

