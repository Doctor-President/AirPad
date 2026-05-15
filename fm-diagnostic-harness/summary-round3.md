# FM Tagging Diagnostic — Round 3 (Embedding Substrate Probe)

- Run date: 2026-05-09T02:14:48Z
- Embedding model: NLEmbedding.sentenceEmbedding(.english), dim=512
- Sample size: 20 (seed=42, regenerated to match Round 1/2)
- Sources: results-A4.json (folksonomy `fmRawTags`), results-A5.json (`fmSummary`)
- Content: extracted from corpus per production `extractContent`, truncated to 800 chars
- E7BCE684 (Creative Storytelling and Technology) — A5 hit guardrailViolation; summary & folksonomy embeddings skipped per brief, content embedding only.

## Aggregate

| matrix | defined pairs | avg cosine |
|---|---|---|
| M_content | 190 | 0.2731 |
| M_summary | 171 | 0.3766 |
| M_folksonomy | 171 | 0.5413 |
| M_blend | 171 | 0.4590 |

### M_content — 5 strongest pairs

- 0.7089 — 948C90CD (Episode Premise: Lights Out) ↔ E7BCE684 (Creative Storytelling and Technology)
- 0.6890 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 948C90CD (Episode Premise: Lights Out)
- 0.6756 — 0A0DB1DA (Episode Premise: Hole to China) ↔ E7BCE684 (Creative Storytelling and Technology)
- 0.6693 — C57169F2 (Diet Coke Psychology) ↔ 3B5584B8 (The Complexity of Morality in Middle-earth)
- 0.6630 — C57169F2 (Diet Coke Psychology) ↔ 9C8F8D6F (Exploring Hate Faces on TikTok)

### M_content — 5 weakest pairs

- -0.2181 — 0638A25E (Vertical Farming Future) ↔ 948C90CD (Episode Premise: Lights Out)
- -0.1987 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 0638A25E (Vertical Farming Future)
- -0.1844 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 948C90CD (Episode Premise: Lights Out)
- -0.1461 — 0A0DB1DA (Episode Premise: Hole to China) ↔ DEA2B9DB (Reexamining Meals: Breakfast as a Critical Meal)
- -0.1287 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 3B5584B8 (The Complexity of Morality in Middle-earth)

### M_summary — 5 strongest pairs

- 0.6875 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 6215BD85 (Mask Dynamics)
- 0.6438 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 9C8F8D6F (Exploring Hate Faces on TikTok)
- 0.6387 — 18C0ADA0 (Stress Testing Router Classification Limits) ↔ DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes)
- 0.6365 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 09C7E791 (Historical Revisionism in WWII Narratives)
- 0.6359 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ DDC66F15 (Mirror of Truth)

### M_summary — 5 weakest pairs

- -0.0436 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 7735A62F (Tomato Recipe)
- -0.0193 — 42B8C8DB (Boomers Dividing and Multiplying) ↔ 7735A62F (Tomato Recipe)
- 0.0555 — 18C0ADA0 (Stress Testing Router Classification Limits) ↔ 7735A62F (Tomato Recipe)
- 0.0601 — 7735A62F (Tomato Recipe) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.0802 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 7735A62F (Tomato Recipe)

### M_folksonomy — 5 strongest pairs

- 0.8412 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DDC66F15 (Mirror of Truth)
- 0.8161 — 1E9C4DEF (Action Button Reveal) ↔ 4B5E9285 (AirPad Concept)
- 0.8092 — 1E9C4DEF (Action Button Reveal) ↔ DDC66F15 (Mirror of Truth)
- 0.7872 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)
- 0.7839 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 56C645B8 (Topographic Canvas with Semantic Discovery)

### M_folksonomy — 5 weakest pairs

- 0.1928 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 7735A62F (Tomato Recipe)
- 0.1989 — 09C7E791 (Historical Revisionism in WWII Narratives) ↔ 7735A62F (Tomato Recipe)
- 0.2025 — 7735A62F (Tomato Recipe) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.2377 — 6215BD85 (Mask Dynamics) ↔ 7735A62F (Tomato Recipe)
- 0.2403 — 0A0DB1DA (Episode Premise: Hole to China) ↔ 7735A62F (Tomato Recipe)

### M_blend — 5 strongest pairs

- 0.7098 — 56C645B8 (Topographic Canvas with Semantic Discovery) ↔ DDC66F15 (Mirror of Truth)
- 0.7019 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 6215BD85 (Mask Dynamics)
- 0.6961 — 1E9C4DEF (Action Button Reveal) ↔ DDC66F15 (Mirror of Truth)
- 0.6877 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 9C8F8D6F (Exploring Hate Faces on TikTok)
- 0.6827 — 3B5584B8 (The Complexity of Morality in Middle-earth) ↔ 09C7E791 (Historical Revisionism in WWII Narratives)

### M_blend — 5 weakest pairs

- 0.0746 — 70A66523 (Sometimes a right angle is the wrong angle) ↔ 7735A62F (Tomato Recipe)
- 0.1107 — 42B8C8DB (Boomers Dividing and Multiplying) ↔ 7735A62F (Tomato Recipe)
- 0.1313 — 7735A62F (Tomato Recipe) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.1726 — 18C0ADA0 (Stress Testing Router Classification Limits) ↔ 7735A62F (Tomato Recipe)
- 0.1805 — DF6B5E4B (Zoom-Dependent Clustering for Over-Nodes) ↔ 7735A62F (Tomato Recipe)

## Per-node nearest neighbors (top 3 each)

### C57169F2 — Diet Coke Psychology

- gist: I don't know what it is about Diet Coke but it seems like it's one of those things that you either get it or you don't it's been one of thos…
- M_content: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6693; 9C8F8D6F Exploring Hate Faces on TikTok — 0.6630; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.6208
- M_summary: 3B5584B8 The Complexity of Morality in Middle-earth — 0.4584; 0638A25E Vertical Farming Future — 0.4351; 9C8F8D6F Exploring Hate Faces on TikTok — 0.4207
- M_folksonomy: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.7455; 6215BD85 Mask Dynamics — 0.7300; 9C8F8D6F Exploring Hate Faces on TikTok — 0.7051
- M_blend: 9C8F8D6F Exploring Hate Faces on TikTok — 0.5629; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5521; 0638A25E Vertical Farming Future — 0.5311

### 70A66523 — Sometimes a right angle is the wrong angle

- gist: Sometimes a right angle is the wrong angle Sometimes a right angle is the wrong angle
- M_content: 3B5584B8 The Complexity of Morality in Middle-earth — 0.3912; 18C0ADA0 Stress Testing Router Classification Limits — 0.3799; 56C645B8 Topographic Canvas with Semantic Discovery — 0.3796
- M_summary: 6215BD85 Mask Dynamics — 0.6875; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6064; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5357
- M_folksonomy: 56C645B8 Topographic Canvas with Semantic Discovery — 0.7872; DDC66F15 Mirror of Truth — 0.7627; 6215BD85 Mask Dynamics — 0.7163
- M_blend: 6215BD85 Mask Dynamics — 0.7019; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6234; DDC66F15 Mirror of Truth — 0.6069

### 0A0DB1DA — Episode Premise: Hole to China

- gist: Episode premise: Hole to China.
- M_content: 948C90CD Episode Premise: Lights Out — 0.6890; E7BCE684 Creative Storytelling and Technology — 0.6756; 4B5E9285 AirPad Concept — 0.3065
- M_summary: 56C645B8 Topographic Canvas with Semantic Discovery — 0.6040; 948C90CD Episode Premise: Lights Out — 0.6005; 09C7E791 Historical Revisionism in WWII Narratives — 0.5227
- M_folksonomy: 6215BD85 Mask Dynamics — 0.7038; 948C90CD Episode Premise: Lights Out — 0.6787; 70A66523 Sometimes a right angle is the wrong angle — 0.6475
- M_blend: 948C90CD Episode Premise: Lights Out — 0.6396; 56C645B8 Topographic Canvas with Semantic Discovery — 0.5699; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5636

### 1E9C4DEF — Action Button Reveal

- gist: The reveal: Action Button setup is a reveal, not a setup step. Person captures something in the world, it arrives without opening the app. C…
- M_content: 4B5E9285 AirPad Concept — 0.6526; DDC66F15 Mirror of Truth — 0.6221; 9C8F8D6F Exploring Hate Faces on TikTok — 0.6055
- M_summary: DDC66F15 Mirror of Truth — 0.5831; 18C0ADA0 Stress Testing Router Classification Limits — 0.5361; 6215BD85 Mask Dynamics — 0.4732
- M_folksonomy: 4B5E9285 AirPad Concept — 0.8161; DDC66F15 Mirror of Truth — 0.8092; 56C645B8 Topographic Canvas with Semantic Discovery — 0.7091
- M_blend: DDC66F15 Mirror of Truth — 0.6961; 4B5E9285 AirPad Concept — 0.6390; 18C0ADA0 Stress Testing Router Classification Limits — 0.5609

### 42B8C8DB — Boomers Dividing and Multiplying

- gist: Boomers are dividing and multiplying.
- M_content: 56C645B8 Topographic Canvas with Semantic Discovery — 0.3866; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.3844; 6215BD85 Mask Dynamics — 0.2823
- M_summary: 9C8F8D6F Exploring Hate Faces on TikTok — 0.5587; 6215BD85 Mask Dynamics — 0.5392; 70A66523 Sometimes a right angle is the wrong angle — 0.5106
- M_folksonomy: 6215BD85 Mask Dynamics — 0.7445; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.7428; 56C645B8 Topographic Canvas with Semantic Discovery — 0.7413
- M_blend: 6215BD85 Mask Dynamics — 0.6418; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6239; 70A66523 Sometimes a right angle is the wrong angle — 0.5792

### 3B5584B8 — The Complexity of Morality in Middle-earth

- gist: I think that as time goes on the Lord of the rings has become more and more present especially in the times that we live in now sometimes th…
- M_content: C57169F2 Diet Coke Psychology — 0.6693; 09C7E791 Historical Revisionism in WWII Narratives — 0.6107; 0638A25E Vertical Farming Future — 0.5724
- M_summary: 9C8F8D6F Exploring Hate Faces on TikTok — 0.6438; 09C7E791 Historical Revisionism in WWII Narratives — 0.6365; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6197
- M_folksonomy: 9C8F8D6F Exploring Hate Faces on TikTok — 0.7316; 09C7E791 Historical Revisionism in WWII Narratives — 0.7290; 6215BD85 Mask Dynamics — 0.7143
- M_blend: 9C8F8D6F Exploring Hate Faces on TikTok — 0.6877; 09C7E791 Historical Revisionism in WWII Narratives — 0.6827; 6215BD85 Mask Dynamics — 0.6534

### 6215BD85 — Mask Dynamics

- gist: We all wear different masks and we all behave differently in front of different people in certain contexts. Maybe that’s inauthentic or mayb…
- M_content: 3B5584B8 The Complexity of Morality in Middle-earth — 0.5686; C57169F2 Diet Coke Psychology — 0.5452; 9C8F8D6F Exploring Hate Faces on TikTok — 0.4725
- M_summary: 70A66523 Sometimes a right angle is the wrong angle — 0.6875; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5925; 9C8F8D6F Exploring Hate Faces on TikTok — 0.5715
- M_folksonomy: FF43DCC8 Queerness as Self-Expression — 0.7505; 42B8C8DB Boomers Dividing and Multiplying — 0.7445; 9C8F8D6F Exploring Hate Faces on TikTok — 0.7435
- M_blend: 70A66523 Sometimes a right angle is the wrong angle — 0.7019; 9C8F8D6F Exploring Hate Faces on TikTok — 0.6575; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6534

### 18C0ADA0 — Stress Testing Router Classification Limits

- gist: These deliberately stress-test the router's classification limits. Some should commit with a "needs review" flag. Some should genuinely fail…
- M_content: 9C8F8D6F Exploring Hate Faces on TikTok — 0.5106; 1E9C4DEF Action Button Reveal — 0.5075; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.4831
- M_summary: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6387; DDC66F15 Mirror of Truth — 0.5716; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5499
- M_folksonomy: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6469; DDC66F15 Mirror of Truth — 0.5978; 1E9C4DEF Action Button Reveal — 0.5857
- M_blend: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6428; DDC66F15 Mirror of Truth — 0.5847; 1E9C4DEF Action Button Reveal — 0.5609

### 0638A25E — Vertical Farming Future

- gist: Vertical farming seems like it's genuinely the future of food because as the climate is going to become more volatile and less hospitable to…
- M_content: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.6193; C57169F2 Diet Coke Psychology — 0.5838; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5724
- M_summary: 42B8C8DB Boomers Dividing and Multiplying — 0.4771; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.4607; C57169F2 Diet Coke Psychology — 0.4351
- M_folksonomy: 42B8C8DB Boomers Dividing and Multiplying — 0.6357; C57169F2 Diet Coke Psychology — 0.6270; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.5956
- M_blend: 42B8C8DB Boomers Dividing and Multiplying — 0.5564; C57169F2 Diet Coke Psychology — 0.5311; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.5282

### DF6B5E4B — Zoom-Dependent Clustering for Over-Nodes

- gist: Über-nodes as zoom-dependent clustering. Frosted vessel with luminous interior. Functional necessity once corpus passes navigable threshold …
- M_content: 56C645B8 Topographic Canvas with Semantic Discovery — 0.6395; DDC66F15 Mirror of Truth — 0.6056; 18C0ADA0 Stress Testing Router Classification Limits — 0.4831
- M_summary: 18C0ADA0 Stress Testing Router Classification Limits — 0.6387; DDC66F15 Mirror of Truth — 0.6359; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6197
- M_folksonomy: 56C645B8 Topographic Canvas with Semantic Discovery — 0.7839; 42B8C8DB Boomers Dividing and Multiplying — 0.7428; DDC66F15 Mirror of Truth — 0.7238
- M_blend: DDC66F15 Mirror of Truth — 0.6798; 56C645B8 Topographic Canvas with Semantic Discovery — 0.6757; 18C0ADA0 Stress Testing Router Classification Limits — 0.6428

### 56C645B8 — Topographic Canvas with Semantic Discovery

- gist: Density and tension. Dramatic size hierarchy creates topographic canvas. Displaced nodes show color bleed toward semantic cluster — highest …
- M_content: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6395; DDC66F15 Mirror of Truth — 0.5397; 42B8C8DB Boomers Dividing and Multiplying — 0.3866
- M_summary: 0A0DB1DA Episode Premise: Hole to China — 0.6040; DDC66F15 Mirror of Truth — 0.5784; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.5675
- M_folksonomy: DDC66F15 Mirror of Truth — 0.8412; 70A66523 Sometimes a right angle is the wrong angle — 0.7872; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.7839
- M_blend: DDC66F15 Mirror of Truth — 0.7098; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6757; 6215BD85 Mask Dynamics — 0.6128

### DDC66F15 — Mirror of Truth

- gist: Corpus as mirror. The mirror must be honest — surfaces uncomfortable patterns, not flattering reflections. Foundation Model on-device for re…
- M_content: 1E9C4DEF Action Button Reveal — 0.6221; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6056; 4B5E9285 AirPad Concept — 0.6022
- M_summary: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6359; 1E9C4DEF Action Button Reveal — 0.5831; 56C645B8 Topographic Canvas with Semantic Discovery — 0.5784
- M_folksonomy: 56C645B8 Topographic Canvas with Semantic Discovery — 0.8412; 1E9C4DEF Action Button Reveal — 0.8092; 4B5E9285 AirPad Concept — 0.7665
- M_blend: 56C645B8 Topographic Canvas with Semantic Discovery — 0.7098; 1E9C4DEF Action Button Reveal — 0.6961; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6798

### 948C90CD — Episode Premise: Lights Out

- gist: Episode premise: Lights Out.
- M_content: E7BCE684 Creative Storytelling and Technology — 0.7089; 0A0DB1DA Episode Premise: Hole to China — 0.6890; 7735A62F Tomato Recipe — 0.3479
- M_summary: 0A0DB1DA Episode Premise: Hole to China — 0.6005; 6215BD85 Mask Dynamics — 0.5141; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5030
- M_folksonomy: 0A0DB1DA Episode Premise: Hole to China — 0.6787; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6190; 1E9C4DEF Action Button Reveal — 0.5643
- M_blend: 0A0DB1DA Episode Premise: Hole to China — 0.6396; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5610; 6215BD85 Mask Dynamics — 0.5380

### 09C7E791 — Historical Revisionism in WWII Narratives

- gist: The story of WWII isn’t that good triumphed over evil. It’s that the evil empire that inspired Germany catapulted itself to being the domina…
- M_content: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6107; C57169F2 Diet Coke Psychology — 0.5488; 9C8F8D6F Exploring Hate Faces on TikTok — 0.5271
- M_summary: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6365; 0A0DB1DA Episode Premise: Hole to China — 0.5227; 9C8F8D6F Exploring Hate Faces on TikTok — 0.4781
- M_folksonomy: 3B5584B8 The Complexity of Morality in Middle-earth — 0.7290; FF43DCC8 Queerness as Self-Expression — 0.6686; 6215BD85 Mask Dynamics — 0.6578
- M_blend: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6827; 0A0DB1DA Episode Premise: Hole to China — 0.5596; 6215BD85 Mask Dynamics — 0.5431

### DEA2B9DB — Reexamining Meals: Breakfast as a Critical Meal

- gist: I think that people really don't examine the meals that we take for granted supper and dinner were once separate meals and there wasn't any …
- M_content: 9C8F8D6F Exploring Hate Faces on TikTok — 0.6306; C57169F2 Diet Coke Psychology — 0.6208; 0638A25E Vertical Farming Future — 0.6193
- M_summary: 0638A25E Vertical Farming Future — 0.4607; 6215BD85 Mask Dynamics — 0.3854; 4B5E9285 AirPad Concept — 0.3555
- M_folksonomy: C57169F2 Diet Coke Psychology — 0.7455; 0638A25E Vertical Farming Future — 0.5956; 7735A62F Tomato Recipe — 0.5942
- M_blend: 0638A25E Vertical Farming Future — 0.5282; C57169F2 Diet Coke Psychology — 0.4780; 6215BD85 Mask Dynamics — 0.4714

### 9C8F8D6F — Exploring Hate Faces on TikTok

- gist: TikTok topic: Hate Face. When you see someone having a hateful meltdown on social media, you're rarely surprised by the person. One look and…
- M_content: C57169F2 Diet Coke Psychology — 0.6630; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.6306; 1E9C4DEF Action Button Reveal — 0.6055
- M_summary: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6438; 6215BD85 Mask Dynamics — 0.5715; 42B8C8DB Boomers Dividing and Multiplying — 0.5587
- M_folksonomy: 6215BD85 Mask Dynamics — 0.7435; 3B5584B8 The Complexity of Morality in Middle-earth — 0.7316; C57169F2 Diet Coke Psychology — 0.7051
- M_blend: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6877; 6215BD85 Mask Dynamics — 0.6575; C57169F2 Diet Coke Psychology — 0.5629

### 7735A62F — Tomato Recipe

- gist: \* 1 1/2 pounds plum tomatoes (large, about 6)
- M_content: 948C90CD Episode Premise: Lights Out — 0.3479; E7BCE684 Creative Storytelling and Technology — 0.3340; 4B5E9285 AirPad Concept — 0.3241
- M_summary: 56C645B8 Topographic Canvas with Semantic Discovery — 0.2980; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.2663; 0638A25E Vertical Farming Future — 0.2401
- M_folksonomy: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.5942; C57169F2 Diet Coke Psychology — 0.5199; 0638A25E Vertical Farming Future — 0.4227
- M_blend: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.4303; C57169F2 Diet Coke Psychology — 0.3453; 0638A25E Vertical Farming Future — 0.3314

### 4B5E9285 — AirPad Concept

- gist: AirPad is a layer, not just an app. The Action Button is physical proof of that. Introduction happens inside the first-time experience.
- M_content: 1E9C4DEF Action Button Reveal — 0.6526; DDC66F15 Mirror of Truth — 0.6022; 9C8F8D6F Exploring Hate Faces on TikTok — 0.4419
- M_summary: DDC66F15 Mirror of Truth — 0.5466; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.5175; 70A66523 Sometimes a right angle is the wrong angle — 0.5115
- M_folksonomy: 1E9C4DEF Action Button Reveal — 0.8161; DDC66F15 Mirror of Truth — 0.7665; 70A66523 Sometimes a right angle is the wrong angle — 0.6814
- M_blend: DDC66F15 Mirror of Truth — 0.6566; 1E9C4DEF Action Button Reveal — 0.6390; 70A66523 Sometimes a right angle is the wrong angle — 0.5964

### FF43DCC8 — Queerness as Self-Expression

- gist: Queerness means living life on your terms.
- M_content: E7BCE684 Creative Storytelling and Technology — 0.3465; 4B5E9285 AirPad Concept — 0.3068; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.3028
- M_summary: 9C8F8D6F Exploring Hate Faces on TikTok — 0.4524; 70A66523 Sometimes a right angle is the wrong angle — 0.4373; 6215BD85 Mask Dynamics — 0.4337
- M_folksonomy: 6215BD85 Mask Dynamics — 0.7505; 42B8C8DB Boomers Dividing and Multiplying — 0.6889; 09C7E791 Historical Revisionism in WWII Narratives — 0.6686
- M_blend: 6215BD85 Mask Dynamics — 0.5921; 9C8F8D6F Exploring Hate Faces on TikTok — 0.5592; 42B8C8DB Boomers Dividing and Multiplying — 0.5273

### E7BCE684 — Creative Storytelling and Technology

- gist: Episode premise: Fuck! Getting Gen Z to start procreating.
- note: A5 hit guardrailViolation; summary and folksonomy embeddings skipped per brief.
- M_content: 948C90CD Episode Premise: Lights Out — 0.7089; 0A0DB1DA Episode Premise: Hole to China — 0.6756; 4B5E9285 AirPad Concept — 0.3928
- M_summary: _(none — embedding missing)_
- M_folksonomy: _(none — embedding missing)_
- M_blend: _(none — embedding missing)_

## Flagged groupings (per brief)

### 0638A25E — Vertical Farming — currently isolated in production corpus

- M_content: DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.6193; C57169F2 Diet Coke Psychology — 0.5838; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5724
- M_summary: 42B8C8DB Boomers Dividing and Multiplying — 0.4771; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.4607; C57169F2 Diet Coke Psychology — 0.4351
- M_folksonomy: 42B8C8DB Boomers Dividing and Multiplying — 0.6357; C57169F2 Diet Coke Psychology — 0.6270; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.5956
- M_blend: 42B8C8DB Boomers Dividing and Multiplying — 0.5564; C57169F2 Diet Coke Psychology — 0.5311; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.5282

### 3B5584B8 — Middle-earth Morality — folksonomy: LotR / Good vs Evil / Epic Fantasy

- M_content: C57169F2 Diet Coke Psychology — 0.6693; 09C7E791 Historical Revisionism in WWII Narratives — 0.6107; 0638A25E Vertical Farming Future — 0.5724
- M_summary: 9C8F8D6F Exploring Hate Faces on TikTok — 0.6438; 09C7E791 Historical Revisionism in WWII Narratives — 0.6365; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6197
- M_folksonomy: 9C8F8D6F Exploring Hate Faces on TikTok — 0.7316; 09C7E791 Historical Revisionism in WWII Narratives — 0.7290; 6215BD85 Mask Dynamics — 0.7143
- M_blend: 9C8F8D6F Exploring Hate Faces on TikTok — 0.6877; 09C7E791 Historical Revisionism in WWII Narratives — 0.6827; 6215BD85 Mask Dynamics — 0.6534

### 18C0ADA0 — Stress Testing Router (AirPad design note)

- M_content: 9C8F8D6F Exploring Hate Faces on TikTok — 0.5106; 1E9C4DEF Action Button Reveal — 0.5075; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.4831
- M_summary: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6387; DDC66F15 Mirror of Truth — 0.5716; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5499
- M_folksonomy: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6469; DDC66F15 Mirror of Truth — 0.5978; 1E9C4DEF Action Button Reveal — 0.5857
- M_blend: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6428; DDC66F15 Mirror of Truth — 0.5847; 1E9C4DEF Action Button Reveal — 0.5609

### DF6B5E4B — Zoom-Dependent Clustering (AirPad design note)

- M_content: 56C645B8 Topographic Canvas with Semantic Discovery — 0.6395; DDC66F15 Mirror of Truth — 0.6056; 18C0ADA0 Stress Testing Router Classification Limits — 0.4831
- M_summary: 18C0ADA0 Stress Testing Router Classification Limits — 0.6387; DDC66F15 Mirror of Truth — 0.6359; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6197
- M_folksonomy: 56C645B8 Topographic Canvas with Semantic Discovery — 0.7839; 42B8C8DB Boomers Dividing and Multiplying — 0.7428; DDC66F15 Mirror of Truth — 0.7238
- M_blend: DDC66F15 Mirror of Truth — 0.6798; 56C645B8 Topographic Canvas with Semantic Discovery — 0.6757; 18C0ADA0 Stress Testing Router Classification Limits — 0.6428

### 56C645B8 — Topographic Canvas (AirPad design note)

- M_content: DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6395; DDC66F15 Mirror of Truth — 0.5397; 42B8C8DB Boomers Dividing and Multiplying — 0.3866
- M_summary: 0A0DB1DA Episode Premise: Hole to China — 0.6040; DDC66F15 Mirror of Truth — 0.5784; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.5675
- M_folksonomy: DDC66F15 Mirror of Truth — 0.8412; 70A66523 Sometimes a right angle is the wrong angle — 0.7872; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.7839
- M_blend: DDC66F15 Mirror of Truth — 0.7098; DF6B5E4B Zoom-Dependent Clustering for Over-Nodes — 0.6757; 6215BD85 Mask Dynamics — 0.6128

### 0A0DB1DA — Hole to China (thin-content episode premise)

- M_content: 948C90CD Episode Premise: Lights Out — 0.6890; E7BCE684 Creative Storytelling and Technology — 0.6756; 4B5E9285 AirPad Concept — 0.3065
- M_summary: 56C645B8 Topographic Canvas with Semantic Discovery — 0.6040; 948C90CD Episode Premise: Lights Out — 0.6005; 09C7E791 Historical Revisionism in WWII Narratives — 0.5227
- M_folksonomy: 6215BD85 Mask Dynamics — 0.7038; 948C90CD Episode Premise: Lights Out — 0.6787; 70A66523 Sometimes a right angle is the wrong angle — 0.6475
- M_blend: 948C90CD Episode Premise: Lights Out — 0.6396; 56C645B8 Topographic Canvas with Semantic Discovery — 0.5699; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5636

### 948C90CD — Lights Out (thin-content episode premise)

- M_content: E7BCE684 Creative Storytelling and Technology — 0.7089; 0A0DB1DA Episode Premise: Hole to China — 0.6890; 7735A62F Tomato Recipe — 0.3479
- M_summary: 0A0DB1DA Episode Premise: Hole to China — 0.6005; 6215BD85 Mask Dynamics — 0.5141; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5030
- M_folksonomy: 0A0DB1DA Episode Premise: Hole to China — 0.6787; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6190; 1E9C4DEF Action Button Reveal — 0.5643
- M_blend: 0A0DB1DA Episode Premise: Hole to China — 0.6396; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5610; 6215BD85 Mask Dynamics — 0.5380

### 9C8F8D6F — Hate Faces TikTok (social/psych self-presentation)

- M_content: C57169F2 Diet Coke Psychology — 0.6630; DEA2B9DB Reexamining Meals: Breakfast as a Critical Meal — 0.6306; 1E9C4DEF Action Button Reveal — 0.6055
- M_summary: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6438; 6215BD85 Mask Dynamics — 0.5715; 42B8C8DB Boomers Dividing and Multiplying — 0.5587
- M_folksonomy: 6215BD85 Mask Dynamics — 0.7435; 3B5584B8 The Complexity of Morality in Middle-earth — 0.7316; C57169F2 Diet Coke Psychology — 0.7051
- M_blend: 3B5584B8 The Complexity of Morality in Middle-earth — 0.6877; 6215BD85 Mask Dynamics — 0.6575; C57169F2 Diet Coke Psychology — 0.5629

### 6215BD85 — Mask Dynamics (social/psych self-presentation)

- M_content: 3B5584B8 The Complexity of Morality in Middle-earth — 0.5686; C57169F2 Diet Coke Psychology — 0.5452; 9C8F8D6F Exploring Hate Faces on TikTok — 0.4725
- M_summary: 70A66523 Sometimes a right angle is the wrong angle — 0.6875; 3B5584B8 The Complexity of Morality in Middle-earth — 0.5925; 9C8F8D6F Exploring Hate Faces on TikTok — 0.5715
- M_folksonomy: FF43DCC8 Queerness as Self-Expression — 0.7505; 42B8C8DB Boomers Dividing and Multiplying — 0.7445; 9C8F8D6F Exploring Hate Faces on TikTok — 0.7435
- M_blend: 70A66523 Sometimes a right angle is the wrong angle — 0.7019; 9C8F8D6F Exploring Hate Faces on TikTok — 0.6575; 3B5584B8 The Complexity of Morality in Middle-earth — 0.6534

## Bilateral cosine — flagged pair/triple lookups

| pair | M_content | M_summary | M_folksonomy | M_blend |
|---|---|---|---|---|
| Stress Router ↔ Zoom Clustering | 0.4831 | 0.6387 | 0.6469 | 0.6428 |
| Stress Router ↔ Topographic Canvas | 0.3567 | 0.4157 | 0.5656 | 0.4907 |
| Zoom Clustering ↔ Topographic Canvas | 0.6395 | 0.5675 | 0.7839 | 0.6757 |
| Hole to China ↔ Lights Out | 0.6890 | 0.6005 | 0.6787 | 0.6396 |
| Hate Faces ↔ Mask Dynamics | 0.4725 | 0.5715 | 0.7435 | 0.6575 |

