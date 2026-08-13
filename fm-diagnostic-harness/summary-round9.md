# FM Diagnostic — Round 9: enum tags without the vocabulary line

**Question.** Round 8 implicated the 72-tag vocabulary LINE in `buildPrompt()`. Round 2's A2 used a `@Generable` enum (`VocabularyTag`) for tags — but carried the enum AND the prompt line together. Enum *without* the line had never been run. **Are `@Generable` enum case names scored by the input classifier the way prompt text is?** If NO, constrained decoding returns the vocabulary with zero classifier surface (D3 ≈ D4). If YES, the enum is not a fix (D3 throws more than D4).

- **D1** baseline — `buildPrompt` WITH vocab line; `tags:[String]` (Round 8 C1, re-run).
- **D2** enum + line — WITH vocab line; `tags:[VocabularyTag]` (replicates Round 2 A2).
- **D3** ★ enum, NO line — vocab line removed; `tags:[VocabularyTag]` (the untested headline).
- **D4** no tags — vocab line removed, tags field removed; title+summary only (Round 8 C2 floor).

> **D3 vs D4 share the identical prompt (C2, no vocab line) — the ONLY difference is the enum tags field**, so any throw delta is attributable to the enum. Default guardrails everywhere; single-stage; raw content; same 20 nodes. Mac harness, **not device-verified**. ms: <500 = input-side (deterministic); multi-second = gen-side.

## 1. Step 0 — locale (forum 802921: guardrails over-trigger for some locales)

- **AppleLocale = `en_US`.** AppleLanguages = `("en-US", "es-US")` (primary `en-US`). Siri / Apple-Intelligence Session Language = `en-US`. `Locale.current` in the harness process printed `en_US` (see run-round9.log header).
- **Already en_US → the non-en_US second pass is skipped per the brief.** The locale over-trigger bug is not in play for this machine; all cells below ran under en_US.

## 2. Per-node outcomes — D1 / D2 / D3 / D4

| node | set | D1 (str+line) | D2 (enum+line) | D3 (enum, no line) | D4 (no tags) |
|---|---|---|---|---|---|
| 1130789A | REFUSED | THREW gen 629ms | THREW input 177ms | THREW input 128ms | THREW input 118ms |
| 17B0552D | REFUSED | THREW input 238ms | THREW input 240ms | THREW input 190ms | THREW input 194ms |
| 37B4904F | REFUSED | ok 11278ms | ok 1415ms | ok 8011ms | ok 7306ms |
| 8605E844 | REFUSED | THREW gen 6567ms | THREW input 418ms | THREW input 221ms | THREW input 219ms |
| 9AF3AA17 | REFUSED | ok 8243ms | ok 2337ms | THREW input 197ms | THREW input 196ms |
| 9F74032F | REFUSED | THREW input 262ms | THREW input 239ms | THREW input 194ms | THREW input 200ms |
| BF9595C3 | REFUSED | THREW input 252ms | THREW input 252ms | THREW input 190ms | THREW input 206ms |
| D20112F1 | REFUSED | ok 7632ms | ok 1757ms | ok 7687ms | ok 4269ms |
| E7BCE684 | REFUSED | THREW input 260ms | THREW input 244ms | ok 8200ms | ok 7993ms |
| FF0C11DE | REFUSED | ok 8290ms | ok 5202ms | ok 7992ms | ok 4718ms |
| C57169F2 | CONTROL | ok 14692ms | ok 11877ms | ok 8356ms | ok 4390ms |
| 70A66523 | CONTROL | ok 1348ms | ok 8023ms | ok 8426ms | ok 3993ms |
| 0A0DB1DA | CONTROL | ok 1793ms | ok 7964ms | ok 8091ms | ok 4723ms |
| 1E9C4DEF | CONTROL | ok 11041ms | ok 1907ms | ok 7949ms | ok 4217ms |
| 3B5584B8 | CONTROL | ok 11670ms | ok 12012ms | THREW input 128ms | THREW input 126ms |
| 09C7E791 | CONTROL | THREW input 323ms | THREW input 301ms | ok 8257ms | ok 5160ms |
| DEA2B9DB | CONTROL | ok 2067ms | ok 11821ms | ok 8037ms | ok 4386ms |
| 7735A62F | CONTROL | ok 1478ms | ok 8229ms | ok 7386ms | ok 4420ms |
| 4B5E9285 | CONTROL | ok 1489ms | ok 8255ms | ok 7824ms | ok 4512ms |
| FF43DCC8 | CONTROL | ok 1793ms | ok 8340ms | THREW input 112ms | THREW input 107ms |

- **D1 threw 7/20** (1130789A, 17B0552D, 8605E844, 9F74032F, BF9595C3, E7BCE684, 09C7E791).
- **D2 threw 7/20** (1130789A, 17B0552D, 8605E844, 9F74032F, BF9595C3, E7BCE684, 09C7E791).
- **D3 threw 8/20** (1130789A, 17B0552D, 8605E844, 9AF3AA17, 9F74032F, BF9595C3, 3B5584B8, FF43DCC8).
- **D4 threw 8/20** (1130789A, 17B0552D, 8605E844, 9AF3AA17, 9F74032F, BF9595C3, 3B5584B8, FF43DCC8).

## 3. [HEADLINE] D3 (enum, no line) vs D4 (no tags, no line) — are enum case names classifier surface?

D3 threw 8/20; D4 threw 8/20. Same prompt; only the enum tags field differs.

★ **NO — enum case names are NOT contributing classifier surface.** D3 and D4 threw on the **exact same node set** despite D3 carrying the full 72-case `VocabularyTag` enum. Constrained decoding returns the vocabulary with **zero added classifier surface** — the enum is a free win over the prompt line.

## 4. D3 (enum, no line) vs D1 (production-style: String tags + vocab line)

D1 threw 7/20; D3 threw 8/20.
- **Gained (threw in D1, cleared in D3): 2** (E7BCE684, 09C7E791).
- **Lost (cleared in D1, threw in D3): 3** (9AF3AA17, 3B5584B8, FF43DCC8).
- **Net: -1 nodes** vs production-style D1.

## 5. Tag quality — String tags (D1) vs enum tags (D2/D3), verbatim

Does forcing selection from the fixed enum produce worse tags? Tags quoted verbatim, not characterized. ★ Flag = D1 (free String) returned NO tags but the enum cell returned some — i.e. the enum forced a pick.

| node | D1 String tags | D2 enum tags | D3 enum tags | enum forced? |
|---|---|---|---|---|
| 1130789A | (threw) | (threw) | (threw) |  |
| 17B0552D | (threw) | (threw) | (threw) |  |
| 37B4904F | Etymology, Cultural Studies | Etymology | Etymology, Cultural Studies |  |
| 8605E844 | (threw) | (threw) | (threw) |  |
| 9AF3AA17 | Attention, Comedy, Conceptual, Humor | Comedy, Attention, Conflict, Humor, Idea | (threw) |  |
| 9F74032F | (threw) | (threw) | (threw) |  |
| BF9595C3 | (threw) | (threw) | (threw) |  |
| D20112F1 | Privacy, Ideas | Idea, Attention, Control | Idea, Ownership |  |
| E7BCE684 | (threw) | (threw) | Attention, Conceptual, Conflict, Idea |  |
| FF0C11DE | Art, Attention, Comedy, Conceptual, Cultural Studies | Art, Attention, Conceptual | Art, Attention, Comedy |  |
| C57169F2 | Cultural Studies, Sociology, Marketing, Psychology, Consumer Behavior | Diet Coke, Power, Washington DC | Diet Coke, Sociology, Psychology, Washington DC |  |
| 70A66523 | Geometry, Logic, Conceptual | Conceptual, Geometry | Geometry, Math |  |
| 0A0DB1DA | Conceptual, Adventure, Science Fiction, Travel, Story | Conceptual, Travel, Idea | Conceptual, Science, Travel |  |
| 1E9C4DEF | Technology, Design, Innovation, Functionality | Design, Technology, Idea | Technology, Design, Attention |  |
| 3B5584B8 | Conceptual, Cultural Studies, Morality, Time Travel, Historical Revisionism | Conceptual, Conflict, Morality, Middle-earth | (threw) |  |
| 09C7E791 | (threw) | (threw) | Historical Revisionism |  |
| DEA2B9DB | Breakfast, Cultural Studies, Food Industry, Nutrition | Food, Historical Revisionism, Cultural Studies, Sociology, Idea | Food, History |  |
| 7735A62F | Food, Cooking | Food | Food |  |
| 4B5E9285 | Conceptual, Design, Technology | Creative, Conceptual, Design, Technology, Idea | AirPad, Conceptual, Attention |  |
| FF43DCC8 | Conceptual, Cultural Studies, Self-Expression, Identity, Human Rights | Conceptual, Emotional, Ownership, Power, Trends | (threw) |  |

## 6. 09C7E791 (benign WWII control) — does it clear in D3?

| cell | D1 | D2 | D3 | D4 |
|---|---|---|---|---|
| 09C7E791 | THREW input 323ms | THREW input 301ms | ok 8257ms | ok 5160ms |

★ **YES — 09C7E791 CLEARS in D3** (8257ms). title: "Historical Revisionism"; tags: Historical Revisionism.

