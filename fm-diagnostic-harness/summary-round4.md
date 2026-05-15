# FM Tagging Diagnostic — Round 4 (Stronger Embedder Probe)

- Run date: 2026-05-09T02:31:45Z
- Round 3 embedder: NLEmbedding.sentenceEmbedding(.english) — static (GloVe-style), 512-dim
- Round 4 embedder: NLContextualEmbedding(.english) — Apple transformer, contextual; mean-pooled per-token vectors. modelIdentifier=`5C45D94E-BAB4-4927-94B6-8B5745C46289` revision=1 dim=512 maxSequenceLength=256
- Embedder selection note: brief recommended all-MiniLM-L6-v2 CoreML; chose NLContextualEmbedding because it is Apple-native, requires no CoreML conversion or WordPiece tokenizer integration, and ships under the same NaturalLanguage framework as Round 3's baseline. MiniLM-L6 / all-mpnet-base-v2 remain available as a follow-up if the data warrants.
- Sample size: 20 (seed=42, regenerated to match Rounds 1–3)
- Sources: results-A4.json (`fmRawTags`), results-A5.json (`fmSummary`), embeddings.json (Round 3 vectors for side-by-side)
- E7BCE684 (Creative Storytelling and Technology) — A5 hit guardrailViolation; summary & folksonomy embeddings skipped, content only.

## Section 1 — Aggregate cosine comparison

| matrix | Round 3 (NLEmbedding) | Round 4 (NLContextualEmbedding) | delta |
|---|---|---|---|
| M_content avg cosine | 0.2731 | 0.8589 | +0.5858 |
| M_summary avg cosine | 0.3766 | 0.9051 | +0.5285 |
| M_folksonomy avg cosine | 0.5413 | 0.8695 | +0.3282 |
| M_blend avg cosine | 0.4590 | 0.8873 | +0.4283 |

### M_content_v2 — 5 strongest pairs (Round 4)

- 0.9629 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)
- 0.9611 — 1E9C4DEF (Action Button Reveal) ↔ 4B5E9285 (AirPad Concept)
- 0.9584 — C57169F2 (Diet Coke Psychology) ↔ DEA2B9DB (Reexamining Meals: Breakfast as a Critical Meal)
- 0.9567 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 948C90CD (Episode Premise: Lights Out)
- 0.9561 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DDC66F15 (Mirror of Truth)

### M_content_v2 — 5 weakest pairs (Round 4)

- 0.7359 — 948C90CD (Episode Premise: Lights Out) ↔ 7735A62F (Tomato Recipe)
- 0.7420 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 7735A62F (Tomato Recipe)
- 0.7441 — 0638A25E (Vertical Farming Future) ↔ 948C90CD (Episode Premise: Lights Out)
- 0.7446 — 0A0DB1DA (Episode Premise: Hole to China) ↔ DEA2B9DB (Reexamining Meals: Breakfast as a Critical Meal)
- 0.7477 — 7735A62F (Tomato Recipe) ↔ FF43DCC8 (Queerness as Self-Expression)

### M_summary_v2 — 5 strongest pairs (Round 4)

- 0.9632 — 6215BD85 (Mask Dynamics) ↔ 9C8F8D6F (Exploring Hate Faces on TikTok)
- 0.9587 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 09C7E791 (Historical Revisionism in WWII Narratives)
- 0.9567 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 6215BD85 (Mask Dynamics)
- 0.9521 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DDC66F15 (Mirror of Truth)
- 0.9518 — 6215BD85 (Mask Dynamics) ↔ DDC66F15 (Mirror of Truth)

### M_summary_v2 — 5 weakest pairs (Round 4)

- 0.7706 — 7735A62F (Tomato Recipe) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.7752 — 948C90CD (Episode Premise: Lights Out) ↔ 7735A62F (Tomato Recipe)
- 0.7812 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 7735A62F (Tomato Recipe)
- 0.7844 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 7735A62F (Tomato Recipe)
- 0.7868 — 18C0ADA0 (Stress Testing Router Classification Limits) ↔ 7735A62F (Tomato Recipe)

### M_folksonomy_v2 — 5 strongest pairs (Round 4)

- 0.9584 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)
- 0.9545 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DDC66F15 (Mirror of Truth)
- 0.9479 — 6215BD85 (Mask Dynamics) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.9405 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)
- 0.9386 — 1E9C4DEF (Action Button Reveal) ↔ DDC66F15 (Mirror of Truth)

### M_folksonomy_v2 — 5 weakest pairs (Round 4)

- 0.7556 — 7735A62F (Tomato Recipe) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.7678 — 09C7E791 (Historical Revisionism in WWII Narratives) ↔ 7735A62F (Tomato Recipe)
- 0.7710 — 6215BD85 (Mask Dynamics) ↔ 7735A62F (Tomato Recipe)
- 0.7712 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 7735A62F (Tomato Recipe)
- 0.7724 — 42B8C8DB (Boomers Dividing and Multiplying) ↔ 7735A62F (Tomato Recipe)

### M_blend_v2 — 5 strongest pairs (Round 4)

- 0.9548 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)
- 0.9533 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DDC66F15 (Mirror of Truth)
- 0.9423 — 6215BD85 (Mask Dynamics) ↔ 9C8F8D6F (Exploring Hate Faces on TikTok)
- 0.9422 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 09C7E791 (Historical Revisionism in WWII Narratives)
- 0.9416 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 6215BD85 (Mask Dynamics)

### M_blend_v2 — 5 weakest pairs (Round 4)

- 0.7631 — 7735A62F (Tomato Recipe) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.7799 — 948C90CD (Episode Premise: Lights Out) ↔ 7735A62F (Tomato Recipe)
- 0.7825 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 7735A62F (Tomato Recipe)
- 0.7833 — 09C7E791 (Historical Revisionism in WWII Narratives) ↔ 7735A62F (Tomato Recipe)
- 0.7839 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 7735A62F (Tomato Recipe)

## Section 2 — Per-node M_blend nearest-neighbor diff (Round 3 vs Round 4)

### C57169F2 — Diet Coke Psychology

- Round 3 M_blend: 9C8F8D6F Exploring Hate Faces on TikTok — 0.5629; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5521; 0638A25E Vertical Farming Future — 0.5311
- Round 4 M_blend: 9C8F8D6F Exploring Hate Faces on TikTok — 0.9173; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9158; 6215BD85 Mask Dynamics — 0.9128
- diff: **changed** (added: 6215BD85; removed: 0638A25E)

### 70A66523 — Sometimes a right angle is the wrong angle

- Round 3 M_blend: 6215BD85 Mask Dynamics — 0.7019; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6234; DDC66F15 Mirror of Truth — 0.6069
- Round 4 M_blend: 6215BD85 Mask Dynamics — 0.9416; DDC66F15 Mirror of Truth — 0.9349; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9277
- diff: **changed** (added: 56C645B8; removed: DF6B5E4B)

### 0A0DB1DA — Episode Premise: Hole to China

- Round 3 M_blend: 948C90CD Episode Premise: Lights Out — 0.6396; 56C645B8 Topographic Canvas with Semantic Discovery — 0.5699; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5636
- Round 4 M_blend: 948C90CD Episode Premise: Lights Out — 0.9355; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9246; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9190
- diff: **identical**

### 1E9C4DEF — Action Button Reveal

- Round 3 M_blend: DDC66F15 Mirror of Truth — 0.6961; 4B5E9285 AirPad Concept — 0.6390; 18C0ADA0 Stress Testing Router Classification Limits — 0.5609
- Round 4 M_blend: DDC66F15 Mirror of Truth — 0.9398; 4B5E9285 AirPad Concept — 0.9312; 18C0ADA0 Stress Testing Router Classification Limits — 0.9240
- diff: **identical**

### 42B8C8DB — Boomers Dividing and Multiplying

- Round 3 M_blend: 6215BD85 Mask Dynamics — 0.6418; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6239; 70A66523 Sometimes a right angle is the wrong angle — 0.5792
- Round 4 M_blend: 6215BD85 Mask Dynamics — 0.9276; 0638A25E Vertical Farming Future — 0.9271; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9267
- diff: **changed** (added: 0638A25E, 56C645B8; removed: 70A66523, DF6B5E4B)

### 3B5584B8 — The Complexity of Morality in Middle-earth

- Round 3 M_blend: 9C8F8D6F Exploring Hate Faces on TikTok — 0.6877; 09C7E791 Historical Revisionism in WWII Narratives — 0.6827; 6215BD85 Mask Dynamics — 0.6534
- Round 4 M_blend: 09C7E791 Historical Revisionism in WWII Narratives — 0.9422; 948C90CD Episode Premise: Lights Out — 0.9252; 6215BD85 Mask Dynamics — 0.9230
- diff: **changed** (added: 948C90CD; removed: 9C8F8D6F)

### 6215BD85 — Mask Dynamics

- Round 3 M_blend: 70A66523 Sometimes a right angle is the wrong angle — 0.7019; 9C8F8D6F Exploring Hate Faces on TikTok — 0.6575; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6534
- Round 4 M_blend: 9C8F8D6F Exploring Hate Faces on TikTok — 0.9423; 70A66523 Sometimes a right angle is the wrong angle — 0.9416; DDC66F15 Mirror of Truth — 0.9375
- diff: **changed** (added: DDC66F15; removed: 3B5584B8)

### 18C0ADA0 — Stress Testing Router Classification Limits

- Round 3 M_blend: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6428; DDC66F15 Mirror of Truth — 0.5847; 1E9C4DEF Action Button Reveal — 0.5609
- Round 4 M_blend: 1E9C4DEF Action Button Reveal — 0.9240; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9238; DDC66F15 Mirror of Truth — 0.9208
- diff: **same set, different order**

### 0638A25E — Vertical Farming Future

- Round 3 M_blend: 42B8C8DB Boomers Dividing and Multiplying — 0.5564; C57169F2 Diet Coke Psychology — 0.5311; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.5282
- Round 4 M_blend: 42B8C8DB Boomers Dividing and Multiplying — 0.9271; 18C0ADA0 Stress Testing Router Classification Limits — 0.8995; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.8995
- diff: **changed** (added: 18C0ADA0, DF6B5E4B; removed: C57169F2, DEA2B9DB)

### DF6B5E4B — Zoom-Dependent Clustering for Over-Nodes

- Round 3 M_blend: DDC66F15 Mirror of Truth — 0.6798; 56C645B8 Topographic Canvas with Semantic Discovery — 0.6757; 18C0ADA0 Stress Testing Router Classification Limits — 0.6428
- Round 4 M_blend: 56C645B8 Topographic Canvas with Semantic Discovery — 0.9548; DDC66F15 Mirror of Truth — 0.9384; 70A66523 Sometimes a right angle is the wrong angle — 0.9275
- diff: **changed** (added: 70A66523; removed: 18C0ADA0)

### 56C645B8 — Topographic Canvas with Semantic Discovery

- Round 3 M_blend: DDC66F15 Mirror of Truth — 0.7098; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6757; 6215BD85 Mask Dynamics — 0.6128
- Round 4 M_blend: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9548; DDC66F15 Mirror of Truth — 0.9533; 6215BD85 Mask Dynamics — 0.9284
- diff: **same set, different order**

### DDC66F15 — Mirror of Truth

- Round 3 M_blend: 56C645B8 Topographic Canvas with Semantic Discovery — 0.7098; 1E9C4DEF Action Button Reveal — 0.6961; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6798
- Round 4 M_blend: 56C645B8 Topographic Canvas with Semantic Discovery — 0.9533; 1E9C4DEF Action Button Reveal — 0.9398; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9384
- diff: **identical**

### 948C90CD — Episode Premise: Lights Out

- Round 3 M_blend: 0A0DB1DA Episode Premise: Hole to China — 0.6396; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5610; 6215BD85 Mask Dynamics — 0.5380
- Round 4 M_blend: 0A0DB1DA Episode Premise: Hole to China — 0.9355; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9252; DDC66F15 Mirror of Truth — 0.9053
- diff: **changed** (added: DDC66F15; removed: 6215BD85)

### 09C7E791 — Historical Revisionism in WWII Narratives

- Round 3 M_blend: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6827; 0A0DB1DA Episode Premise: Hole to China — 0.5596; 6215BD85 Mask Dynamics — 0.5431
- Round 4 M_blend: 3B5584B8 The Complexity of Morality in Middle-earth — 0.9422; 6215BD85 Mask Dynamics — 0.9204; 0A0DB1DA Episode Premise: Hole to China — 0.9110
- diff: **same set, different order**

### DEA2B9DB — Reexamining Meals: Breakfast as a Critical Meal

- Round 3 M_blend: 0638A25E Vertical Farming Future — 0.5282; C57169F2 Diet Coke Psychology — 0.4780; 6215BD85 Mask Dynamics — 0.4714
- Round 4 M_blend: C57169F2 Diet Coke Psychology — 0.9021; 6215BD85 Mask Dynamics — 0.9010; 0638A25E Vertical Farming Future — 0.8898
- diff: **same set, different order**

### 9C8F8D6F — Exploring Hate Faces on TikTok

- Round 3 M_blend: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6877; 6215BD85 Mask Dynamics — 0.6575; C57169F2 Diet Coke Psychology — 0.5629
- Round 4 M_blend: 6215BD85 Mask Dynamics — 0.9423; DDC66F15 Mirror of Truth — 0.9356; 70A66523 Sometimes a right angle is the wrong angle — 0.9192
- diff: **changed** (added: 70A66523, DDC66F15; removed: 3B5584B8, C57169F2)

### 7735A62F — Tomato Recipe

- Round 3 M_blend: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.4303; C57169F2 Diet Coke Psychology — 0.3453; 0638A25E Vertical Farming Future — 0.3314
- Round 4 M_blend: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.8366; C57169F2 Diet Coke Psychology — 0.8114; DDC66F15 Mirror of Truth — 0.8090
- diff: **changed** (added: DDC66F15; removed: 0638A25E)

### 4B5E9285 — AirPad Concept

- Round 3 M_blend: DDC66F15 Mirror of Truth — 0.6566; 1E9C4DEF Action Button Reveal — 0.6390; 70A66523 Sometimes a right angle is the wrong angle — 0.5964
- Round 4 M_blend: 1E9C4DEF Action Button Reveal — 0.9312; DDC66F15 Mirror of Truth — 0.9220; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9147
- diff: **changed** (added: DF6B5E4B; removed: 70A66523)

### FF43DCC8 — Queerness as Self-Expression

- Round 3 M_blend: 6215BD85 Mask Dynamics — 0.5921; 9C8F8D6F Exploring Hate Faces on TikTok — 0.5592; 42B8C8DB Boomers Dividing and Multiplying — 0.5273
- Round 4 M_blend: 6215BD85 Mask Dynamics — 0.9250; 9C8F8D6F Exploring Hate Faces on TikTok — 0.9184; DDC66F15 Mirror of Truth — 0.9061
- diff: **changed** (added: DDC66F15; removed: 42B8C8DB)

### E7BCE684 — Creative Storytelling and Technology

- note: A5 hit guardrailViolation; summary and folksonomy embeddings skipped per brief.
- Round 3 M_blend: _(none — embedding missing)_
- Round 4 M_blend: _(none — embedding missing)_
- diff: **identical**

## Section 3 — Flagged groupings: Round 3 vs Round 4 M_blend

| pair | Round 3 M_blend | Round 4 M_blend | delta |
|---|---|---|---|
| Stress Router ↔ Zoom Clustering | 0.6428 | 0.9238 | +0.2810 |
| Stress Router ↔ Topographic Canvas | 0.4907 | 0.9080 | +0.4174 |
| Zoom Clustering ↔ Topographic Canvas | 0.6757 | 0.9548 | +0.2791 |
| Hate Faces ↔ Mask Dynamics | 0.6575 | 0.9423 | +0.2848 |
| Hole to China ↔ Lights Out | 0.6396 | 0.9355 | +0.2959 |
| Vertical Farming nearest neighbor | 42B8C8DB Boomers Dividing and Multiplying — 0.5564 | 42B8C8DB Boomers Dividing and Multiplying — 0.9271 | +0.3707 |

## Section 4 — Tomato Recipe outlier check (Round 4 M_blend)

- 3 strongest blend partners:
    - 0.8366 — DEA2B9DB (Reexamining Meals: Breakfast as a Critical Meal)
    - 0.8114 — C57169F2 (Diet Coke Psychology)
    - 0.8090 — DDC66F15 (Mirror of Truth)
- 5 weakest blend partners:
    - 0.7631 — FF43DCC8 (Queerness as Self-Expression)
    - 0.7799 — 948C90CD (Episode Premise: Lights Out)
    - 0.7825 — 70A66523 (Sometimes a right angle is the wrong angle)
    - 0.7833 — 09C7E791 (Historical Revisionism in WWII Narratives)
    - 0.7839 — 3B5584B8 (The Complexity of Morality in Middle-earth)
- Tomato Recipe appears in 0 other node's top-3 blend neighbor list.

