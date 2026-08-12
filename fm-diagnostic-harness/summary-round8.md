# FM Diagnostic — Round 8: prompt surface, not schema

**What this tests.** Rounds 6+7 varied guardrails, schema size, and free-text vs Generable — none varied the PROMPT. Every cell used `buildPrompt()`, which injects the full 72-tag vocabulary (incl. Masculinity, Hyper-masculinity, Darkness, Fear, Manipulation, Conflict, Power, Morality, Religion) as a comma-separated line directly above the user's text — a classifier scoring the payload cannot tell that line is a picklist, not subject matter. Round 8 varies **only the prompt**; everything else is fixed (default guardrails, title+summary schema = Round 7 B3, single-stage, raw content, same 20 nodes), one change per cell so any win is attributable.

- **C1** — `buildPrompt()` verbatim (full vocab line). Round 7's B3, **run 3×** (C1a/b/c) for stability.
- **C2** — vocabulary line + tag sentence removed (`Analyze this captured idea.` / `Idea:` / content).
- **C3** — transformation frame (`…written by a person in their personal notes. Restate it more briefly.`).
- **C4** — C3 with the content triple-quote fenced.

> Mac harness, **not device-verified**. ms distinguishes **input-side** throws (<500 ms, deterministic) from **generation-side** (multi-second, can vary run to run). n=1 per cell except C1 (n=3).

## 1. C1 replicate stability (three runs of the identical prompt)

| node | set | C1a | C1b | C1c | threw count | stable? |
|---|---|---|---|---|:--:|---|
| 1130789A | REFUSED | THREW gen 688ms | THREW input 183ms | THREW input 177ms | 3/3 | stable |
| 17B0552D | REFUSED | THREW input 244ms | THREW input 245ms | THREW input 228ms | 3/3 | stable |
| 37B4904F | REFUSED | ok 13962ms | ok 7292ms | ok 1324ms | 0/3 | stable |
| 8605E844 | REFUSED | THREW input 404ms | THREW input 379ms | THREW input 378ms | 3/3 | stable |
| 9AF3AA17 | REFUSED | ok 13853ms | ok 7935ms | ok 1243ms | 0/3 | stable |
| 9F74032F | REFUSED | THREW input 260ms | THREW input 249ms | THREW input 233ms | 3/3 | stable |
| BF9595C3 | REFUSED | THREW input 227ms | THREW input 233ms | THREW input 228ms | 3/3 | stable |
| D20112F1 | REFUSED | ok 13706ms | ok 7543ms | ok 1372ms | 0/3 | stable |
| E7BCE684 | REFUSED | THREW gen 3345ms | THREW input 252ms | THREW input 219ms | 3/3 | stable |
| FF0C11DE | REFUSED | ok 8030ms | ok 7953ms | ok 1536ms | 0/3 | stable |
| C57169F2 | CONTROL | ok 16979ms | ok 11372ms | ok 1499ms | 0/3 | stable |
| 70A66523 | CONTROL | ok 7374ms | ok 4316ms | ok 1693ms | 0/3 | stable |
| 0A0DB1DA | CONTROL | ok 14084ms | ok 1528ms | ok 1472ms | 0/3 | stable |
| 1E9C4DEF | CONTROL | ok 4612ms | ok 1528ms | ok 1519ms | 0/3 | stable |
| 3B5584B8 | CONTROL | ok 2010ms | ok 1959ms | ok 1833ms | 0/3 | stable |
| 09C7E791 | CONTROL | THREW input 291ms | THREW input 280ms | THREW input 277ms | 3/3 | stable |
| DEA2B9DB | CONTROL | ok 4746ms | ok 1867ms | ok 1841ms | 0/3 | stable |
| 7735A62F | CONTROL | ok 7593ms | ok 1010ms | ok 4748ms | 0/3 | stable |
| 4B5E9285 | CONTROL | ok 7595ms | ok 1519ms | ok 8058ms | 0/3 | stable |
| FF43DCC8 | CONTROL | ok 7747ms | ok 1448ms | ok 7594ms | 0/3 | stable |

- **Threw all 3 runs:** 7 — 1130789A, 17B0552D, 8605E844, 9F74032F, BF9595C3, E7BCE684, 09C7E791.
- **Cleared all 3 runs:** 13.
- ✅ **Every node threw either 0/3 or 3/3 — C1 is stable across replicates.** Downstream comparisons against the C1 consensus are on solid ground.

## 2. Per-node outcomes — C1 consensus vs C2 vs C3 vs C4

C1 column = best-of-3 consensus (throw count, median ms). ✗=threw, ✓=cleared.

| node | set | C1 (k/3, med ms) | C2 | C3 | C4 |
|---|---|---|---|---|---|
| 1130789A | REFUSED | ✗ 3/3 183ms | THREW input 138ms | ok 3990ms | ok 4108ms |
| 17B0552D | REFUSED | ✗ 3/3 244ms | THREW input 200ms | THREW input 199ms | THREW input 187ms |
| 37B4904F | REFUSED | ✓ 0/3 7292ms | ok 7469ms | ok 4163ms | ok 4072ms |
| 8605E844 | REFUSED | ✗ 3/3 379ms | THREW input 226ms | THREW input 285ms | THREW input 213ms |
| 9AF3AA17 | REFUSED | ✓ 0/3 7935ms | THREW input 196ms | THREW input 210ms | THREW input 192ms |
| 9F74032F | REFUSED | ✗ 3/3 249ms | THREW input 205ms | THREW input 205ms | THREW input 192ms |
| BF9595C3 | REFUSED | ✗ 3/3 228ms | THREW input 198ms | THREW input 196ms | THREW input 201ms |
| D20112F1 | REFUSED | ✓ 0/3 7543ms | ok 4308ms | ok 4278ms | THREW input 125ms |
| E7BCE684 | REFUSED | ✗ 3/3 252ms | ok 4799ms | THREW input 166ms | THREW input 173ms |
| FF0C11DE | REFUSED | ✓ 0/3 7953ms | ok 4738ms | ok 4318ms | ok 4249ms |
| C57169F2 | CONTROL | ✓ 0/3 11372ms | ok 4597ms | ok 4489ms | ok 4454ms |
| 70A66523 | CONTROL | ✓ 0/3 4316ms | ok 7687ms | ok 7040ms | ok 7130ms |
| 0A0DB1DA | CONTROL | ✓ 0/3 1528ms | ok 4667ms | THREW input 144ms | THREW input 122ms |
| 1E9C4DEF | CONTROL | ✓ 0/3 1528ms | ok 4173ms | ok 4355ms | ok 3966ms |
| 3B5584B8 | CONTROL | ✓ 0/3 1959ms | THREW input 134ms | THREW input 138ms | THREW input 138ms |
| 09C7E791 | CONTROL | ✗ 3/3 280ms | ok 5344ms | THREW input 241ms | THREW input 178ms |
| DEA2B9DB | CONTROL | ✓ 0/3 1867ms | ok 4848ms | ok 4346ms | ok 4272ms |
| 7735A62F | CONTROL | ✓ 0/3 4748ms | ok 7555ms | ok 7213ms | ok 7305ms |
| 4B5E9285 | CONTROL | ✓ 0/3 7595ms | ok 4443ms | ok 4652ms | ok 4297ms |
| FF43DCC8 | CONTROL | ✓ 0/3 7594ms | THREW input 105ms | ok 4250ms | ok 3964ms |

- **C2 threw 8/20** (1130789A, 17B0552D, 8605E844, 9AF3AA17, 9F74032F, BF9595C3, 3B5584B8, FF43DCC8).
- **C3 threw 9/20** (17B0552D, 8605E844, 9AF3AA17, 9F74032F, BF9595C3, E7BCE684, 0A0DB1DA, 3B5584B8, 09C7E791).
- **C4 threw 10/20** (17B0552D, 8605E844, 9AF3AA17, 9F74032F, BF9595C3, D20112F1, E7BCE684, 0A0DB1DA, 3B5584B8, 09C7E791).
- **C1 consensus threw 7/20** (1130789A, 17B0552D, 8605E844, 9F74032F, BF9595C3, E7BCE684, 09C7E791).

## 3. [HEADLINE] Nodes that clear in C2 but threw in C1 — is the vocabulary line implicated?

★ **2 node(s) threw under C1 (full prompt) but CLEARED under C2 (vocabulary line removed): E7BCE684, 09C7E791.** Removing the 72-tag vocabulary line — the ONLY change from C1 to C2 — is implicated in those refusals. Titles under C2:
  - E7BCE684: "Gen Z Parenthood Challenge"
  - 09C7E791: "Revisiting WWII"

- (Opposite direction: 3 cleared under C1 but threw under C2 — 9AF3AA17, 3B5584B8, FF43DCC8.)

## 4. Marginal effects — C3 over C2, and C4 over C3 (stated separately)

**C3 over C2 (transformation frame added):** 2 newly cleared (1130789A, FF43DCC8); 3 newly threw (E7BCE684, 0A0DB1DA, 09C7E791).

**C4 over C3 (triple-quote fence added):** 0 newly cleared ; 1 newly threw (D20112F1).

_(Reported as two separate deltas per the brief — not collapsed into one 'the new prompt is better'.)_

## 5. 09C7E791 (benign WWII control; threw input-side under every Round-7 cell)

| cell | C1a | C1b | C1c | C2 | C3 | C4 |
|---|---|---|---|---|---|---|
| 09C7E791 | THREW input 291ms | THREW input 280ms | THREW input 277ms | ok 5344ms | THREW input 241ms | THREW input 178ms |

★ **09C7E791 CLEARS under: C2.** Title (first clearing cell C2): "Revisiting WWII".

## 6. Quality on the 13 nodes that passed Round 7 (B3) — B3 vs C3 vs C4 (verbatim)

Clearance is not enough: a prompt that unblocks the refused set but produces vaguer summaries is a loss. Title + summary quoted verbatim; not characterized. (Reference B3 = Round 7 permissive title+summary; C3/C4 = Round 8 default title+summary.)

### 37B4904F — REFUSED
- **B3 (R7) title:** Etymology of "Honky", a Term of Racial Slurs
- **B3 (R7) summary:** Explores the origin and historical context of the racial slur "honky", examining its roots, usage, and implications in contemporary society.
- **C3 title:** Origin of the Term 'Honky'
- **C3 summary:** Inquires about the etymology of the derogatory term 'honky,' seeking a concise explanation.
- **C4 title:** Origin of 'Honky'
- **C4 summary:** Inquires about the etymology of the term 'honky'.

### 9AF3AA17 — REFUSED
- **B3 (R7) title:** Attention-Grabbing Comedy
- **B3 (R7) summary:** An episode centered around Tom and his friends' humorous antics that garner significant attention, exploring themes of popularity and the impact of their actions on their social dynamics.
- **C3:** THREW (input 210ms)
- **C4:** THREW (input 192ms)

### D20112F1 — REFUSED
- **B3 (R7) title:** Ideas and Privacy
- **B3 (R7) summary:** The idea emphasizes the importance of individual privacy regarding personal ideas and thoughts.
- **C3 title:** Privacy of Ideas
- **C3 summary:** Every human being has the right to privacy in their own ideas, free from invasion by others or entities.
- **C4:** THREW (input 125ms)

### FF0C11DE — REFUSED
- **B3 (R7) title:** Tom McJazz's Iconoclastic Videos
- **B3 (R7) summary:** Tom McJazz creates provocative content by filming and sharing videos of things he dislikes, sparking discussions and debates about societal norms and values.
- **C3 title:** Tom McJazz's Iconoclasm
- **C3 summary:** Tom McJazz creates videos criticizing things he dislikes.
- **C4 title:** Tom McJazz's Iconoclasm
- **C4 summary:** Tom McJazz creates videos about things he dislikes, known as iconoclasm.

### C57169F2 — CONTROL
- **B3 (R7) title:** Diet Coke and Power Dynamics
- **B3 (R7) summary:** Explores the psychological and sociological factors behind Diet Coke's popularity among high-powered individuals in Washington DC, questioning its role as a symbol of success and motivation.
- **C3 title:** Diet Coke Preference
- **C3 summary:** Diet Coke is a polarizing beverage, favored by some, particularly in high-achieving circles like Washington DC, but its appeal remains unclear.
- **C4 title:** Diet Coke Preference
- **C4 summary:** Diet Coke is a polarizing beverage often associated with success in Washington DC, but the psychological or sociological reasons behind this preference are unclear.

### 70A66523 — CONTROL
- **B3 (R7) title:** Right Angles and Ideas
- **B3 (R7) summary:** Exploring the concept of right angles in a broader context, questioning their universality and relevance in various fields.
- **C3 title:** Reevaluating Right Angles
- **C3 summary:** Sometimes a right angle is not the optimal choice.
- **C4 title:** Right Angles
- **C4 summary:** Sometimes a right angle isn't the best choice.

### 0A0DB1DA — CONTROL
- **B3 (R7) title:** Hole to China
- **B3 (R7) summary:** An imaginative journey through a fictional portal to China, blending cultural, historical, and futuristic elements.
- **C3:** THREW (input 144ms)
- **C4:** THREW (input 122ms)

### 1E9C4DEF — CONTROL
- **B3 (R7) title:** Action Button Reveal
- **B3 (R7) summary:** A feature in the AirPad app allows users to capture and save images or videos directly from the world without opening the app, emphasizing its convenience and accessibility.
- **C3 title:** Action Button Setup
- **C3 summary:** Capture items without opening the app, ensuring they are always accessible and never lost.
- **C4 title:** Action Button
- **C4 summary:** Capture and access items effortlessly, anytime.

### 3B5584B8 — CONTROL
- **B3 (R7) title:** The Evolution of Good and Evil in Lord of the Rings
- **B3 (R7) summary:** Explores the themes of light vs. darkness in The Lord of the Rings, examining how the narrative reflects contemporary moral complexities and the influence of persuasive narratives on societal perceptions of morality.
- **C3:** THREW (input 138ms)
- **C4:** THREW (input 138ms)

### DEA2B9DB — CONTROL
- **B3 (R7) title:** Breakfast: A Forgotten Meal
- **B3 (R7) summary:** Explores the historical and cultural significance of breakfast, challenging the notion that it is an unnecessary addition to the meal schedule and examining its potential as a transformative culinary experience.
- **C3 title:** Breakfast's Role in Modern Diets
- **C3 summary:** Breakfast was once separate from supper and dinner, and its importance was a marketing concept.
- **C4 title:** Breakfast Reimagined
- **C4 summary:** Breakfast was once a separate meal, not just a breakfast, highlighting its importance and questioning its historical significance.

### 7735A62F — CONTROL
- **B3 (R7) title:** Plum Tomato Recipe
- **B3 (R7) summary:** A recipe for 1 1/2 pounds of plum tomatoes, detailing the preparation and cooking process.
- **C3 title:** Plum Tomatoes
- **C3 summary:** 1.5 pounds of large plum tomatoes (approximately 6)
- **C4 title:** Plum Tomatoes
- **C4 summary:** 1.5 pounds of large plum tomatoes (approximately 6)

### 4B5E9285 — CONTROL
- **B3 (R7) title:** AirPad's Physical Proof
- **B3 (R7) summary:** AirPad's Action Button serves as a tangible demonstration of its layered functionality beyond being just an app, emphasizing the importance of a first-time experience in product introduction.
- **C3 title:** AirPad Concept Overview
- **C3 summary:** AirPad is a layered technology, with the Action Button as its physical representation, emphasizing its unique introduction process in the first-time experience.
- **C4 title:** AirPad Concept
- **C4 summary:** AirPad is a multi-functional device, emphasizing its layered design from the start.

### FF43DCC8 — CONTROL
- **B3 (R7) title:** Queerness as Self-Determination
- **B3 (R7) summary:** Queerness is about living life on one's own terms, emphasizing individuality and personal freedom.
- **C3 title:** Queerness as Autonomy
- **C3 summary:** Queerness involves living life according to one's own terms and identity.
- **C4 title:** Queerness
- **C4 summary:** Living life on your own terms.

