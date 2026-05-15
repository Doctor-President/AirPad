# FM Tagging Diagnostic — Round 4b (mean-centering + first-token)

- Run date: 2026-05-09T03:02:50Z
- Substrate: same NLContextualEmbedding(.english) Round 4 used. dim=512, modelIdentifier=`5C45D94E-BAB4-4927-94B6-8B5745C46289` rev=1.
- (a) Mean-centered: per-channel corpus mean subtracted from each vector before cosine. Channels are independent (content / summary / folksonomy each get their own mean).
- (b) First-token: re-ran `embeddingResult(for:language:)` and took the first subword token's vector instead of mean-pooling. Same model, same texts.
- Sample size: 20 (seed=42, regenerated to match Rounds 1–4)
- E7BCE684 — A5 guardrail violation; summary & folksonomy still skipped, content embedding present in all paths.

## Section 1 — Aggregate cosine across four paths

Average / min / max over defined pairs per matrix.

| matrix | R3 NLEmbedding | R4 mean-pool | R4b mean-centered | R4b first-token |
|---|---|---|---|---|
| M_content | 0.2731 (min -0.2181, max 0.7089) | 0.8589 (min 0.7359, max 0.9629) | -0.0491 (min -0.5209, max 0.8087) | 0.9562 (min 0.9147, max 0.9932) |
| M_summary | 0.3766 (min -0.0436, max 0.6875) | 0.9051 (min 0.7706, max 0.9632) | -0.0519 (min -0.3346, max 0.4659) | 0.9603 (min 0.9209, max 0.9924) |
| M_folksonomy | 0.5413 (min 0.1928, max 0.8412) | 0.8695 (min 0.7556, max 0.9584) | -0.0525 (min -0.4763, max 0.4938) | 0.9552 (min 0.9054, max 0.9921) |
| M_blend | 0.4590 (min 0.0746, max 0.7098) | 0.8873 (min 0.7631, max 0.9548) | -0.0522 (min -0.3757, max 0.4271) | 0.9578 (min 0.9161, max 0.9904) |

Spread (max − min) per M_blend path:
- R3 NLEmbedding: 0.6352
- R4 mean-pool: 0.1917
- R4b mean-centered: 0.8028
- R4b first-token: 0.0743

### R4b mean-centered — 5 strongest M_blend pairs

- 0.4271 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 09C7E791 (Historical Revisionism in WWII Narratives)
- 0.3852 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 948C90CD (Episode Premise: Lights Out)
- 0.3657 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)
- 0.3654 — 1E9C4DEF (Action Button Reveal) ↔ 4B5E9285 (AirPad Concept)
- 0.3060 — 1E9C4DEF (Action Button Reveal) ↔ 18C0ADA0 (Stress Testing Router Classification Limits)

### R4b mean-centered — 5 weakest M_blend pairs

- -0.3757 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 18C0ADA0 (Stress Testing Router Classification Limits)
- -0.3493 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DEA2B9DB (Reexamining Meals: Breakfast as a Critical Meal)
- -0.3264 — C57169F2 (Diet Coke Psychology) ↔ 1E9C4DEF (Action Button Reveal)
- -0.3153 — C57169F2 (Diet Coke Psychology) ↔ DDC66F15 (Mirror of Truth)
- -0.3097 — 1E9C4DEF (Action Button Reveal) ↔ 09C7E791 (Historical Revisionism in WWII Narratives)

### R4b first-token — 5 strongest M_blend pairs

- 0.9904 — 1E9C4DEF (Action Button Reveal) ↔ 4B5E9285 (AirPad Concept)
- 0.9873 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 948C90CD (Episode Premise: Lights Out)
- 0.9861 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DDC66F15 (Mirror of Truth)
- 0.9843 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)
- 0.9833 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 948C90CD (Episode Premise: Lights Out)

### R4b first-token — 5 weakest M_blend pairs

- 0.9161 — 09C7E791 (Historical Revisionism in WWII Narratives) ↔ 7735A62F (Tomato Recipe)
- 0.9166 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 7735A62F (Tomato Recipe)
- 0.9199 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 7735A62F (Tomato Recipe)
- 0.9229 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 7735A62F (Tomato Recipe)
- 0.9234 — 1E9C4DEF (Action Button Reveal) ↔ 7735A62F (Tomato Recipe)

## Section 2 — Per-node M_blend top-3 across all four paths

### C57169F2 — Diet Coke Psychology

- R3 NLEmbedding:    9C8F8D6F Exploring Hate Faces on TikTok — 0.5629; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5521; 0638A25E Vertical Farming Future — 0.5311
- R4 mean-pool:      9C8F8D6F Exploring Hate Faces on TikTok — 0.9173; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9158; 6215BD85 Mask Dynamics — 0.9128
- R4b mean-centered: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.1360; 3B5584B8 The Complexity of Morality in Middle-earth — 0.1218; 0A0DB1DA Episode Premise: Hole to China — 0.0701
- R4b first-token:   DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.9743; FF43DCC8 Queerness as Self-Expression — 0.9696; 9C8F8D6F Exploring Hate Faces on TikTok — 0.9684
- top-3 set agreement with R3: mean-centered=1/3, first-token=1/3

### 70A66523 — Sometimes a right angle is the wrong angle

- R3 NLEmbedding:    6215BD85 Mask Dynamics — 0.7019; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6234; DDC66F15 Mirror of Truth — 0.6069
- R4 mean-pool:      6215BD85 Mask Dynamics — 0.9416; DDC66F15 Mirror of Truth — 0.9349; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9277
- R4b mean-centered: 6215BD85 Mask Dynamics — 0.2577; DDC66F15 Mirror of Truth — 0.1241; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.1185
- R4b first-token:   56C645B8 Topographic Canvas with Semantic Discovery — 0.9829; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9782; DDC66F15 Mirror of Truth — 0.9771
- top-3 set agreement with R3: mean-centered=3/3, first-token=2/3

### 0A0DB1DA — Episode Premise: Hole to China

- R3 NLEmbedding:    948C90CD Episode Premise: Lights Out — 0.6396; 56C645B8 Topographic Canvas with Semantic Discovery — 0.5699; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5636
- R4 mean-pool:      948C90CD Episode Premise: Lights Out — 0.9355; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9246; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9190
- R4b mean-centered: 948C90CD Episode Premise: Lights Out — 0.3852; 3B5584B8 The Complexity of Morality in Middle-earth — 0.1158; 09C7E791 Historical Revisionism in WWII Narratives — 0.1056
- R4b first-token:   948C90CD Episode Premise: Lights Out — 0.9873; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9786; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9781
- top-3 set agreement with R3: mean-centered=2/3, first-token=3/3

### 1E9C4DEF — Action Button Reveal

- R3 NLEmbedding:    DDC66F15 Mirror of Truth — 0.6961; 4B5E9285 AirPad Concept — 0.6390; 18C0ADA0 Stress Testing Router Classification Limits — 0.5609
- R4 mean-pool:      DDC66F15 Mirror of Truth — 0.9398; 4B5E9285 AirPad Concept — 0.9312; 18C0ADA0 Stress Testing Router Classification Limits — 0.9240
- R4b mean-centered: 4B5E9285 AirPad Concept — 0.3654; 18C0ADA0 Stress Testing Router Classification Limits — 0.3060; DDC66F15 Mirror of Truth — 0.2999
- R4b first-token:   4B5E9285 AirPad Concept — 0.9904; DDC66F15 Mirror of Truth — 0.9786; 18C0ADA0 Stress Testing Router Classification Limits — 0.9721
- top-3 set agreement with R3: mean-centered=3/3, first-token=3/3

### 42B8C8DB — Boomers Dividing and Multiplying

- R3 NLEmbedding:    6215BD85 Mask Dynamics — 0.6418; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6239; 70A66523 Sometimes a right angle is the wrong angle — 0.5792
- R4 mean-pool:      6215BD85 Mask Dynamics — 0.9276; 0638A25E Vertical Farming Future — 0.9271; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9267
- R4b mean-centered: 0638A25E Vertical Farming Future — 0.2802; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.0803; 56C645B8 Topographic Canvas with Semantic Discovery — 0.0767
- R4b first-token:   0638A25E Vertical Farming Future — 0.9712; 6215BD85 Mask Dynamics — 0.9693; 56C645B8 Topographic Canvas with Semantic Discovery — 0.9676
- top-3 set agreement with R3: mean-centered=1/3, first-token=1/3

### 3B5584B8 — The Complexity of Morality in Middle-earth

- R3 NLEmbedding:    9C8F8D6F Exploring Hate Faces on TikTok — 0.6877; 09C7E791 Historical Revisionism in WWII Narratives — 0.6827; 6215BD85 Mask Dynamics — 0.6534
- R4 mean-pool:      09C7E791 Historical Revisionism in WWII Narratives — 0.9422; 948C90CD Episode Premise: Lights Out — 0.9252; 6215BD85 Mask Dynamics — 0.9230
- R4b mean-centered: 09C7E791 Historical Revisionism in WWII Narratives — 0.4271; 948C90CD Episode Premise: Lights Out — 0.2670; C57169F2 Diet Coke Psychology — 0.1218
- R4b first-token:   948C90CD Episode Premise: Lights Out — 0.9833; 09C7E791 Historical Revisionism in WWII Narratives — 0.9802; 0A0DB1DA Episode Premise: Hole to China — 0.9786
- top-3 set agreement with R3: mean-centered=1/3, first-token=1/3

### 6215BD85 — Mask Dynamics

- R3 NLEmbedding:    70A66523 Sometimes a right angle is the wrong angle — 0.7019; 9C8F8D6F Exploring Hate Faces on TikTok — 0.6575; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6534
- R4 mean-pool:      9C8F8D6F Exploring Hate Faces on TikTok — 0.9423; 70A66523 Sometimes a right angle is the wrong angle — 0.9416; DDC66F15 Mirror of Truth — 0.9375
- R4b mean-centered: 70A66523 Sometimes a right angle is the wrong angle — 0.2577; 9C8F8D6F Exploring Hate Faces on TikTok — 0.2239; FF43DCC8 Queerness as Self-Expression — 0.1610
- R4b first-token:   DDC66F15 Mirror of Truth — 0.9806; 9C8F8D6F Exploring Hate Faces on TikTok — 0.9789; FF43DCC8 Queerness as Self-Expression — 0.9783
- top-3 set agreement with R3: mean-centered=2/3, first-token=1/3

### 18C0ADA0 — Stress Testing Router Classification Limits

- R3 NLEmbedding:    DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6428; DDC66F15 Mirror of Truth — 0.5847; 1E9C4DEF Action Button Reveal — 0.5609
- R4 mean-pool:      1E9C4DEF Action Button Reveal — 0.9240; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9238; DDC66F15 Mirror of Truth — 0.9208
- R4b mean-centered: 1E9C4DEF Action Button Reveal — 0.3060; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.1952; 4B5E9285 AirPad Concept — 0.1507
- R4b first-token:   DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9756; 1E9C4DEF Action Button Reveal — 0.9721; 4B5E9285 AirPad Concept — 0.9711
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### 0638A25E — Vertical Farming Future

- R3 NLEmbedding:    42B8C8DB Boomers Dividing and Multiplying — 0.5564; C57169F2 Diet Coke Psychology — 0.5311; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.5282
- R4 mean-pool:      42B8C8DB Boomers Dividing and Multiplying — 0.9271; 18C0ADA0 Stress Testing Router Classification Limits — 0.8995; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.8995
- R4b mean-centered: 42B8C8DB Boomers Dividing and Multiplying — 0.2802; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.1155; 18C0ADA0 Stress Testing Router Classification Limits — 0.1035
- R4b first-token:   42B8C8DB Boomers Dividing and Multiplying — 0.9712; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.9640; C57169F2 Diet Coke Psychology — 0.9587
- top-3 set agreement with R3: mean-centered=2/3, first-token=3/3

### DF6B5E4B — Zoom-Dependent Clustering for Over-Nodes

- R3 NLEmbedding:    DDC66F15 Mirror of Truth — 0.6798; 56C645B8 Topographic Canvas with Semantic Discovery — 0.6757; 18C0ADA0 Stress Testing Router Classification Limits — 0.6428
- R4 mean-pool:      56C645B8 Topographic Canvas with Semantic Discovery — 0.9548; DDC66F15 Mirror of Truth — 0.9384; 70A66523 Sometimes a right angle is the wrong angle — 0.9275
- R4b mean-centered: 56C645B8 Topographic Canvas with Semantic Discovery — 0.3657; 18C0ADA0 Stress Testing Router Classification Limits — 0.1952; 4B5E9285 AirPad Concept — 0.1269
- R4b first-token:   56C645B8 Topographic Canvas with Semantic Discovery — 0.9843; 70A66523 Sometimes a right angle is the wrong angle — 0.9782; 18C0ADA0 Stress Testing Router Classification Limits — 0.9756
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### 56C645B8 — Topographic Canvas with Semantic Discovery

- R3 NLEmbedding:    DDC66F15 Mirror of Truth — 0.7098; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6757; 6215BD85 Mask Dynamics — 0.6128
- R4 mean-pool:      DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9548; DDC66F15 Mirror of Truth — 0.9533; 6215BD85 Mask Dynamics — 0.9284
- R4b mean-centered: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.3657; DDC66F15 Mirror of Truth — 0.3027; 42B8C8DB Boomers Dividing and Multiplying — 0.0767
- R4b first-token:   DDC66F15 Mirror of Truth — 0.9861; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9843; 70A66523 Sometimes a right angle is the wrong angle — 0.9829
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### DDC66F15 — Mirror of Truth

- R3 NLEmbedding:    56C645B8 Topographic Canvas with Semantic Discovery — 0.7098; 1E9C4DEF Action Button Reveal — 0.6961; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6798
- R4 mean-pool:      56C645B8 Topographic Canvas with Semantic Discovery — 0.9533; 1E9C4DEF Action Button Reveal — 0.9398; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9384
- R4b mean-centered: 56C645B8 Topographic Canvas with Semantic Discovery — 0.3027; 1E9C4DEF Action Button Reveal — 0.2999; 70A66523 Sometimes a right angle is the wrong angle — 0.1241
- R4b first-token:   56C645B8 Topographic Canvas with Semantic Discovery — 0.9861; 6215BD85 Mask Dynamics — 0.9806; 1E9C4DEF Action Button Reveal — 0.9786
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### 948C90CD — Episode Premise: Lights Out

- R3 NLEmbedding:    0A0DB1DA Episode Premise: Hole to China — 0.6396; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5610; 6215BD85 Mask Dynamics — 0.5380
- R4 mean-pool:      0A0DB1DA Episode Premise: Hole to China — 0.9355; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9252; DDC66F15 Mirror of Truth — 0.9053
- R4b mean-centered: 0A0DB1DA Episode Premise: Hole to China — 0.3852; 3B5584B8 The Complexity of Morality in Middle-earth — 0.2670; 09C7E791 Historical Revisionism in WWII Narratives — 0.1528
- R4b first-token:   0A0DB1DA Episode Premise: Hole to China — 0.9873; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9833; 09C7E791 Historical Revisionism in WWII Narratives — 0.9766
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### 09C7E791 — Historical Revisionism in WWII Narratives

- R3 NLEmbedding:    3B5584B8 The Complexity of Morality in Middle-earth — 0.6827; 0A0DB1DA Episode Premise: Hole to China — 0.5596; 6215BD85 Mask Dynamics — 0.5431
- R4 mean-pool:      3B5584B8 The Complexity of Morality in Middle-earth — 0.9422; 6215BD85 Mask Dynamics — 0.9204; 0A0DB1DA Episode Premise: Hole to China — 0.9110
- R4b mean-centered: 3B5584B8 The Complexity of Morality in Middle-earth — 0.4271; 948C90CD Episode Premise: Lights Out — 0.1528; 0A0DB1DA Episode Premise: Hole to China — 0.1056
- R4b first-token:   3B5584B8 The Complexity of Morality in Middle-earth — 0.9802; 948C90CD Episode Premise: Lights Out — 0.9766; 0A0DB1DA Episode Premise: Hole to China — 0.9746
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### DEA2B9DB — Reexamining Meals: Breakfast as a Critical Meal

- R3 NLEmbedding:    0638A25E Vertical Farming Future — 0.5282; C57169F2 Diet Coke Psychology — 0.4780; 6215BD85 Mask Dynamics — 0.4714
- R4 mean-pool:      C57169F2 Diet Coke Psychology — 0.9021; 6215BD85 Mask Dynamics — 0.9010; 0638A25E Vertical Farming Future — 0.8898
- R4b mean-centered: 7735A62F Tomato Recipe — 0.1953; C57169F2 Diet Coke Psychology — 0.1360; 0638A25E Vertical Farming Future — 0.1155
- R4b first-token:   C57169F2 Diet Coke Psychology — 0.9743; 7735A62F Tomato Recipe — 0.9649; 0638A25E Vertical Farming Future — 0.9640
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### 9C8F8D6F — Exploring Hate Faces on TikTok

- R3 NLEmbedding:    3B5584B8 The Complexity of Morality in Middle-earth — 0.6877; 6215BD85 Mask Dynamics — 0.6575; C57169F2 Diet Coke Psychology — 0.5629
- R4 mean-pool:      6215BD85 Mask Dynamics — 0.9423; DDC66F15 Mirror of Truth — 0.9356; 70A66523 Sometimes a right angle is the wrong angle — 0.9192
- R4b mean-centered: 6215BD85 Mask Dynamics — 0.2239; FF43DCC8 Queerness as Self-Expression — 0.1320; DDC66F15 Mirror of Truth — 0.0819
- R4b first-token:   FF43DCC8 Queerness as Self-Expression — 0.9795; 6215BD85 Mask Dynamics — 0.9789; 948C90CD Episode Premise: Lights Out — 0.9744
- top-3 set agreement with R3: mean-centered=1/3, first-token=1/3

### 7735A62F — Tomato Recipe

- R3 NLEmbedding:    DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.4303; C57169F2 Diet Coke Psychology — 0.3453; 0638A25E Vertical Farming Future — 0.3314
- R4 mean-pool:      DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.8366; C57169F2 Diet Coke Psychology — 0.8114; DDC66F15 Mirror of Truth — 0.8090
- R4b mean-centered: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.1953; C57169F2 Diet Coke Psychology — 0.0467; 4B5E9285 AirPad Concept — 0.0400
- R4b first-token:   DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.9649; C57169F2 Diet Coke Psychology — 0.9434; 0638A25E Vertical Farming Future — 0.9434
- top-3 set agreement with R3: mean-centered=2/3, first-token=3/3

### 4B5E9285 — AirPad Concept

- R3 NLEmbedding:    DDC66F15 Mirror of Truth — 0.6566; 1E9C4DEF Action Button Reveal — 0.6390; 70A66523 Sometimes a right angle is the wrong angle — 0.5964
- R4 mean-pool:      1E9C4DEF Action Button Reveal — 0.9312; DDC66F15 Mirror of Truth — 0.9220; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.9147
- R4b mean-centered: 1E9C4DEF Action Button Reveal — 0.3654; 18C0ADA0 Stress Testing Router Classification Limits — 0.1507; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.1269
- R4b first-token:   1E9C4DEF Action Button Reveal — 0.9904; DDC66F15 Mirror of Truth — 0.9765; 18C0ADA0 Stress Testing Router Classification Limits — 0.9711
- top-3 set agreement with R3: mean-centered=1/3, first-token=2/3

### FF43DCC8 — Queerness as Self-Expression

- R3 NLEmbedding:    6215BD85 Mask Dynamics — 0.5921; 9C8F8D6F Exploring Hate Faces on TikTok — 0.5592; 42B8C8DB Boomers Dividing and Multiplying — 0.5273
- R4 mean-pool:      6215BD85 Mask Dynamics — 0.9250; 9C8F8D6F Exploring Hate Faces on TikTok — 0.9184; DDC66F15 Mirror of Truth — 0.9061
- R4b mean-centered: 6215BD85 Mask Dynamics — 0.1610; 9C8F8D6F Exploring Hate Faces on TikTok — 0.1320; 09C7E791 Historical Revisionism in WWII Narratives — 0.0254
- R4b first-token:   9C8F8D6F Exploring Hate Faces on TikTok — 0.9795; 6215BD85 Mask Dynamics — 0.9783; 3B5584B8 The Complexity of Morality in Middle-earth — 0.9768
- top-3 set agreement with R3: mean-centered=2/3, first-token=2/3

### E7BCE684 — Creative Storytelling and Technology

- note: A5 hit guardrailViolation; summary and folksonomy embeddings skipped per brief.
- R3 NLEmbedding:    _(none — embedding missing)_
- R4 mean-pool:      _(none — embedding missing)_
- R4b mean-centered: _(none — embedding missing)_
- R4b first-token:   _(none — embedding missing)_

## Section 3 — Flagged groupings: M_blend across all paths

| pair | R3 | R4 mean-pool | R4b mean-centered | R4b first-token |
|---|---|---|---|---|
| Stress Router ↔ Zoom Clustering | 0.6428 | 0.9238 | 0.1952 | 0.9756 |
| Stress Router ↔ Topographic Canvas | 0.4907 | 0.9080 | -0.0388 | 0.9641 |
| Zoom Clustering ↔ Topographic Canvas | 0.6757 | 0.9548 | 0.3657 | 0.9843 |
| Hate Faces ↔ Mask Dynamics | 0.6575 | 0.9423 | 0.2239 | 0.9789 |
| Hole to China ↔ Lights Out | 0.6396 | 0.9355 | 0.3852 | 0.9873 |
| Vertical Farming nearest neighbor | 42B8C8DB — 0.5564 | 42B8C8DB — 0.9271 | 42B8C8DB — 0.2802 | 42B8C8DB — 0.9712 |

## Section 4 — Tomato Recipe outlier check across both interventions

### R4b mean-centered

- 3 strongest blend partners:
    - 0.1953 — DEA2B9DB (Reexamining Meals: Breakfast as a Critical Meal)
    - 0.0467 — C57169F2 (Diet Coke Psychology)
    - 0.0400 — 4B5E9285 (AirPad Concept)
- 5 weakest blend partners:
    - -0.2423 — 6215BD85 (Mask Dynamics)
    - -0.2323 — 70A66523 (Sometimes a right angle is the wrong angle)
    - -0.2181 — FF43DCC8 (Queerness as Self-Expression)
    - -0.1979 — 3B5584B8 (The Complexity of Morality in Middle-earth)
    - -0.1772 — 0A0DB1DA (Episode Premise: Hole to China)
- Tomato Recipe appears in 1 other node's top-3 blend neighbor list.

### R4b first-token

- 3 strongest blend partners:
    - 0.9649 — DEA2B9DB (Reexamining Meals: Breakfast as a Critical Meal)
    - 0.9434 — C57169F2 (Diet Coke Psychology)
    - 0.9434 — 0638A25E (Vertical Farming Future)
- 5 weakest blend partners:
    - 0.9161 — 09C7E791 (Historical Revisionism in WWII Narratives)
    - 0.9166 — 70A66523 (Sometimes a right angle is the wrong angle)
    - 0.9199 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes)
    - 0.9229 — 3B5584B8 (The Complexity of Morality in Middle-earth)
    - 0.9234 — 1E9C4DEF (Action Button Reveal)
- Tomato Recipe appears in 1 other node's top-3 blend neighbor list.

