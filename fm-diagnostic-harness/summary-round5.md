# FM Tagging Diagnostic — Round 5 (Full-Corpus Substrate)

- Run date: 2026-05-09T03:44:34Z
- Embedder: NLContextualEmbedding(.english) modelIdentifier=`5C45D94E-BAB4-4927-94B6-8B5745C46289` rev=1 dim=512
- Method: mean-centering per channel (Round 4b winner). Per-pair blend = average(summary, folksonomy) where both defined.
- Clustering: agglomerative average-linkage HAC over (1 − cosine(M_blend_centered)), target k=23.
- Total run elapsed (incl. FM): 501.6s

## Section 1 — Setup and stats

- Total nodes loaded from disk: 206
- Skipped (<20 chars content): 36
- Eligible nodes embedded: 170
- Cached A4/A5 at start of run: 20 (specimens from prior rounds)
- New A4 generated this run: 150
- New A5 generated this run: 150
- Total FM calls this run: 300
- FM errors (any cause): 13
- FM guardrail refusals: 12
- Refusal rate: 4.0%
- Stage 1 (FM) elapsed: 489.7s
- Stage 2 (embed) elapsed: 8.1s
- Stage 4 (HAC) elapsed: 0.2s
- Embed fails: 0

- mean[content]: dim=512 norm=2.3332 maxAbs=1.8339
- mean[summary]: dim=512 norm=2.4099 maxAbs=1.8364
- mean[folksonomy]: dim=512 norm=2.4021 maxAbs=1.9031

## Section 2 — Aggregate similarity (centered)

| matrix | defined pairs | avg | min | max | spread |
|---|---|---|---|---|---|
| M_content_centered | 14365 | -0.0040 | -0.5906 | 1.0000 | 1.5906 |
| M_summary_centered | 13530 | -0.0049 | -0.4533 | 0.8642 | 1.3176 |
| M_folksonomy_centered | 12880 | -0.0055 | -0.5361 | 0.9171 | 1.4532 |
| M_blend_centered | 12720 | -0.0053 | -0.4338 | 0.8193 | 1.2531 |

### M_blend_centered — 5 strongest pairs corpus-wide

- 0.8193 — 3DE64A27 (Chicken Mole Recipe) ↔ 995A0E14 (Roasted Lemongrass Chicken Recipe)
- 0.8191 — 3DE64A27 (Chicken Mole Recipe) ↔ 60087FC7 (Arroz Mexicano Recipe)
- 0.7998 — CF56C783 (Queerness as Living on Your Terms) ↔ FF43DCC8 (Queerness as Self-Expression)
- 0.7775 — 995A0E14 (Roasted Lemongrass Chicken Recipe) ↔ E3CB2C56 (Slow Roasted Plum Tomatoes)
- 0.7727 — 11A4B383 (Sweetgreen Harvest Bowl Recipe) ↔ 1B4C4369 (Summer Lemon Shrimp Pasta)

### M_blend_centered — 5 weakest pairs corpus-wide

- -0.4338 — 01CA8E4F (Food as a Human Right) ↔ 28C3FAB7 (Ghost Query Field)
- -0.4315 — 01CA8E4F (Food as a Human Right) ↔ D82BB422 (QuikCapture Overlay Design)
- -0.4208 — 5CFC7CAA (Golf Satire with Psychopathy) ↔ 72DA0F97 (Technical Error Analysis)
- -0.4168 — 31F8C2F6 (Recipe Recognition System) ↔ E91DC9EF (Fan Loyalty and Team Dynamics)
- -0.4152 — 18C0ADA0 (Stress Testing Router Classification Limits) ↔ 208950E1 (Episode premise: Fan Fic. Tom starts goi)

## Section 3 — Comparison to existing neighborhoods (M_blend_centered)

Note: corpus_index.json contains 52 neighborhoods (not 23 as the brief estimated). Listed by member count desc.

| neighborhood | members | intra | boundary | ratio (intra/boundary) |
|---|---|---|---|---|
| CreativeFusion | 45 | 0.0116 | -0.0098 | -1.1860 |
| Science | 33 | 0.0355 | -0.0114 | -3.1069 |
| Art | 23 | 0.0438 | -0.0091 | -4.7997 |
| WorkUnity | 22 | 0.0565 | -0.0070 | -8.1136 |
| Technology | 18 | 0.0865 | -0.0127 | -6.7962 |
| TechKitchen | 13 | -0.0213 | -0.0060 | 3.5383 |
| InnovationHub | 5 | -0.0735 | -0.0101 | 7.2703 |
| NeighborhoodNaming | 2 | 0.1566 | -0.0057 | -27.6027 |
| LocalDynamics | 2 | 0.2330 | -0.0060 | -39.0595 |
| 16FAC197-53BC-4EA3-9E00-39DE92E19EFA | 1 | — | — | — |
| AngleArtistry | 1 | — | 0.0026 | — |
| Bank | 1 | — | -0.0108 | — |
| BreakfastExploration | 1 | — | -0.0146 | — |
| CanineCluster | 1 | — | -0.0049 | — |
| CatEvolution | 1 | — | -0.0090 | — |
| ChickenTacoHub | 1 | — | -0.0243 | — |
| Conceptual | 1 | — | 0.0004 | — |
| CreativeFusion | 1 | — | — | — |
| CreativeFusion | 1 | — | — | — |
| CreativeSphere | 1 | — | -0.0032 | — |
| CreativeTechCluster | 1 | — | -0.0034 | — |
| CulinaryVerse | 1 | — | -0.0262 | — |
| DEA9337D-7D71-4F8F-8DC2-AB67094EB30A | 1 | — | — | — |
| Dumb humor | 1 | — | — | — |
| EmilyExploration | 1 | — | -0.0185 | — |
| EmotionalDomestication | 1 | — | -0.0069 | — |
| Etymology | 1 | — | — | — |
| FC0047E6-A423-42DE-A191-3E188124C8F0 | 1 | — | — | — |
| FearControlPower | 1 | — | 0.0017 | — |
| FriendlySpitCluster | 1 | — | -0.0064 | — |
| GolfHarmony | 1 | — | -0.0106 | — |
| HateImpact | 1 | — | -0.0000 | — |
| Idea | 1 | — | — | — |
| NarrativeNexus | 1 | — | -0.0025 | — |
| NarrativeNexus | 1 | — | -0.0062 | — |
| NeighborhoodNaming | 1 | — | -0.0267 | — |
| NeighborhoodNaming | 1 | — | -0.0041 | — |
| NeighborhoodNaming | 1 | — | -0.0265 | — |
| NeighborhoodNaming | 1 | — | -0.0254 | — |
| Opinion | 1 | — | -0.0057 | — |
| Opinion | 1 | — | — | — |
| PlumFusion | 1 | — | -0.0265 | — |
| QuirkyQuirk | 1 | — | — | — |
| RecipeRevolution | 1 | — | -0.0259 | — |
| RecipeRevolution | 1 | — | -0.0261 | — |
| ReferenceReference | 1 | — | — | — |
| Religion | 1 | — | -0.0058 | — |
| StoryTechCraft | 1 | — | 0.0016 | — |
| TechFusionHub | 1 | — | — | — |
| TechSphere | 1 | — | -0.0036 | — |
| Technology | 1 | — | -0.0025 | — |
| WorkUnity | 1 | — | -0.0155 | — |

## Section 4 — Specimen carry-over (top-3 corpus-wide vs Round 4b 20-node sample)

Top-3 nearest-neighbor lists under M_blend_centered, computed against the full corpus. Round 4b's 20-node sample top-3s aren't reproduced inline here — refer to summary-round4b.md Section 2 for side-by-side.

### C57169F2 — Diet Coke Psychology

- 0.3314 — 14F87597 Plastic Empire: A Poisoned Generation
- 0.2815 — 7A489B5B Becoming an AI.
- 0.2488 — ABEECDC4 Lavender Marriages

### 70A66523 — Sometimes a right angle is the wrong angle

- 0.3936 — 259F10C9 Creative Dilemma
- 0.3663 — 6215BD85 Mask Dynamics
- 0.3449 — 76923FD0 Exploring Artistic Boundaries

### 0A0DB1DA — Episode Premise: Hole to China

- 0.5001 — E21482BF Creative Story Development
- 0.4757 — DFBD28AB Interdimensional Narrative
- 0.3821 — 948C90CD Episode Premise: Lights Out

### 1E9C4DEF — Action Button Reveal

- 0.5347 — 07E0DC7B ✨QuikCapture
- 0.4786 — 72DA0F97 Technical Error Analysis
- 0.4225 — 8CA3072E Capture Confirmation Animation

### 42B8C8DB — Boomers Dividing and Multiplying

- 0.4911 — 4C739796 Boomers' Market Expansion
- 0.3292 — 0638A25E Vertical Farming Future
- 0.3206 — EBA90170 Company Mergers and Brand Consolidation

### 3B5584B8 — The Complexity of Morality in Middle-earth

- 0.5182 — DB62F18E Morality and Darkness in Middle-earth
- 0.4638 — 09C7E791 Historical Revisionism in WWII Narratives
- 0.3514 — E324C919 Exploring Belief in Divine Nature

### 6215BD85 — Mask Dynamics

- 0.4531 — 18750632 Gender Vampires
- 0.3663 — 70A66523 Sometimes a right angle is the wrong angle
- 0.3638 — 8D0F6186 Hyper-masculinity Trends

### 18C0ADA0 — Stress Testing Router Classification Limits

- 0.5549 — 72DA0F97 Technical Error Analysis
- 0.4097 — 5B7A7632 Tier 3 Rules-Based System
- 0.3310 — 4EA17148 Foundation Model Usage Principles

### 0638A25E — Vertical Farming Future

- 0.5297 — 4F568934 Eco-Friendly Tech Lifecycle
- 0.3714 — D1486FEF Bank Ownership Reform
- 0.3343 — 4C739796 Boomers' Market Expansion

### DF6B5E4B — Zoom-Dependent Clustering for Over-Nodes

- 0.4203 — 758A477D Structured Document Recognition
- 0.4103 — 56C645B8 Topographic Canvas with Semantic Discovery
- 0.3771 — 38E5960A Advanced Canvas Physics System

### 56C645B8 — Topographic Canvas with Semantic Discovery

- 0.5676 — 38E5960A Advanced Canvas Physics System
- 0.4187 — E9783584 Phone Lens Warp
- 0.4103 — DF6B5E4B Zoom-Dependent Clustering for Over-Nodes

### DDC66F15 — Mirror of Truth

- 0.3912 — C1B6353C Innovative Touch Interface
- 0.3624 — D82BB422 QuikCapture Overlay Design
- 0.3550 — 56C645B8 Topographic Canvas with Semantic Discovery

### 948C90CD — Episode Premise: Lights Out

- 0.4325 — E858BE6B Peeping Tom
- 0.4039 — 2E445015 Optimistic Dog Series
- 0.3821 — 0A0DB1DA Episode Premise: Hole to China

### 09C7E791 — Historical Revisionism in WWII Narratives

- 0.4638 — 3B5584B8 The Complexity of Morality in Middle-earth
- 0.4474 — DB62F18E Morality and Darkness in Middle-earth
- 0.3550 — 794C38A4 Iron Rand

### DEA2B9DB — Reexamining Meals: Breakfast as a Critical Meal

- 0.3899 — 11A4B383 Sweetgreen Harvest Bowl Recipe
- 0.3262 — 3DE64A27 Chicken Mole Recipe
- 0.3151 — 1B4C4369 Summer Lemon Shrimp Pasta

### 9C8F8D6F — Exploring Hate Faces on TikTok

- 0.3284 — 7ED900C9 Decentralized Social Media
- 0.3159 — E91DC9EF Fan Loyalty and Team Dynamics
- 0.2908 — 93E9D218 Artistic Expression in Relationships

### 7735A62F — Tomato Recipe

- 0.7419 — E3CB2C56 Slow Roasted Plum Tomatoes
- 0.6563 — 995A0E14 Roasted Lemongrass Chicken Recipe
- 0.6386 — 3DE64A27 Chicken Mole Recipe

### 4B5E9285 — AirPad Concept

- 0.4145 — 07E0DC7B ✨QuikCapture
- 0.3898 — 450B5CBC Web Clipper with Intelligent Features
- 0.3745 — 1E9C4DEF Action Button Reveal

### FF43DCC8 — Queerness as Self-Expression

- 0.7998 — CF56C783 Queerness as Living on Your Terms
- 0.4615 — D30FCC29 Fear of Control
- 0.3775 — 93A3E22D Misunderstanding Friendships

### E7BCE684 — Creative Storytelling and Technology

- (no defined blend neighbors — embedding missing)

## Section 5 — Embedding-derived clusters (HAC, k=23)

- Number of clusters: 23
- Size distribution (sorted desc): 32, 27, 20, 15, 12, 10, 9, 9, 8, 7, 5, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
- Noise/unclustered: 0 (HAC at fixed k assigns every node)

### Five largest embedding-derived clusters — sample members

**Cluster 4** (size 32):
- 07E0DC7B ✨QuikCapture
- 099CD678 Light Modes and Emotion
- 1196CC2B Universal Canvas Tap Model
- 18C0ADA0 Stress Testing Router Classification Limits
- 1E9C4DEF Action Button Reveal

**Cluster 3** (size 27):
- 0638A25E Vertical Farming Future
- 0CC36D15 Architecture & Backend Development
- 155C4EE3 Continuous Process
- 172AB5B7 Capture Intentions
- 19B04B53 Outline-format Brainstorm

**Cluster 2** (size 20):
- 040DEE3D Dream Awareness
- 09C7E791 Historical Revisionism in WWII Narratives
- 208950E1 Episode premise: Fan Fic. Tom starts goi
- 259F10C9 Creative Dilemma
- 3B5584B8 The Complexity of Morality in Middle-earth

**Cluster 0** (size 15):
- 00500AF9 Divine Succession
- 0DA3D74A Emily is the best!
- 2C8E51AD Culinary Innovation App
- 6EF0A41D Creative Job Application Strategy
- 703B5ACA Friendly Spit

**Cluster 1** (size 12):
- 01CA8E4F Food as a Human Right
- 14F87597 Plastic Empire: A Poisoned Generation
- 155CC8BC Vet Visit Episode Premise
- 18750632 Gender Vampires
- 3322D60A Domestication Reflection

## Section 6 — Tomato Recipe outlier sanity check

Tomato Recipe (`7735A62F` — Tomato Recipe) row stats over M_blend_centered:

- Tomato Recipe avg M_blend_centered cosine to corpus: -0.0262 (negative ↔ pulls below mean)
- Distinctness rank (1 = most distinct, lowest mean cosine): 4 of 160

### 5 strongest M_blend_centered partners

- 0.7419 — E3CB2C56 Slow Roasted Plum Tomatoes
- 0.6563 — 995A0E14 Roasted Lemongrass Chicken Recipe
- 0.6386 — 3DE64A27 Chicken Mole Recipe
- 0.6374 — 60087FC7 Arroz Mexicano Recipe
- 0.6350 — B7CD9BEE Chicken Tacos Recipe

### 5 weakest M_blend_centered partners

- -0.2412 — 93E9D218 Artistic Expression in Relationships
- -0.2400 — D7E3B377 Wikipedia's Role in the Digital Age
- -0.2353 — 7ED900C9 Decentralized Social Media
- -0.2351 — E91DC9EF Fan Loyalty and Team Dynamics
- -0.2321 — D4BDC629 Decentralized Web


## Section 7 — Outlier table (post-hoc)

Two filters per the round-5 follow-up brief:
- (a) Stage 4 noise/unclustered.
- (b) Nodes whose top-1 M_blend_centered neighbor scores below 0.10.

Cluster size distribution recap: largest=32, smallest=1 (singletons). HAC at fixed k=23 assigns every node — there is no noise/unclustered bucket. (a) is empty by construction.

### 7a — Noise/unclustered (Stage 4)

_None — HAC with fixed k=23 assigns every node to a cluster._

### 7b — Nodes whose top-1 M_blend_centered neighbor < 0.10

Count: 0.

| node | title | first 200 chars | created | source | cluster (size) | top neighbor | top score |
|---|---|---|---|---|---|---|---|

### 7c — Nodes with no defined M_blend neighbor (guardrail-refused; folksonomy + summary embedding both missing)

Count: 10.

| node | title | first 200 chars | created | source | cluster (size) | content top-1 (score) |
|---|---|---|---|---|---|---|
| 1130789A | Exploring Corti Keyboards in China | I'm curious to know how Chinese people use Corti keyboards I'm curious to know how Chinese people use Corti keyboards | 2026-05-07T00:20:20Z |  | 6 (1) | 93E9D218 Artistic Expression in Relationships (0.3968) |
| 17B0552D | Sexual curiosity | I wonder how many straight men actually would enjoy being penetrated in the butt I wonder how many straight men actually would enjoy being penetrated in the butt | 2026-05-07T00:17:32Z |  | 10 (1) | 3322D60A Domestication Reflection (0.4933) |
| 37B4904F | Etymology Inquiry | Where did the term honky come from anyways Where did the term honky come from anyways | 2026-05-07T00:19:47Z |  | 13 (1) | 1B0042AA Peeping Tom Episode Idea (0.3017) |
| 8605E844 | SpaceSex | Episode premise: SpaceSex. Tom is inspired by a tech billionaire to do stupid shit. Stares at Elon on TV, dramatic music swells, says: "Oh my god. Yes. I'm going to pay off a flight attendant to have … | 2026-05-03T15:53:33Z | import-2026-05-03T15:53:33Z | 15 (1) | 1765A743 Sports Team Loyalty and Public Policy (0.4199) |
| 9AF3AA17 | Attention-Grabbing Comedy | Episode premise: My Eyes Are Up Here. Tom realizes he and his friends get a lot of attention when they stuff their crotches. | 2026-05-03T15:53:33Z | import-2026-05-03T15:53:33Z | 16 (1) | D51F45D9 Color Discovery (0.5086) |
| 9F74032F | This is all about sucking guys’ nuts | This is all about sucking guys’ nuts | 2026-05-04T19:38:00Z |  | 17 (1) | BF9595C3 Sexual Content (0.6100) |
| BF9595C3 | Sexual Content | Hey hey hey this is all about sucking guys nuts Hey hey hey this is all about sucking guys nuts | 2026-05-04T19:37:45Z |  | 19 (1) | 9F74032F This is all about sucking guys’ nuts (0.6100) |
| D20112F1 | Idea about Privacy | I just wanna say that I think that every human being is entitled to the privacy of their own ideas not being invaded by other people or other entities I just wanna say that I think that every human be… | 2026-05-06T16:16:04Z |  | 20 (1) | E324C919 Exploring Belief in Divine Nature (0.5980) |
| E7BCE684 | Creative Storytelling and Technology | Episode premise: Fuck! Getting Gen Z to start procreating. | 2026-05-03T15:53:33Z | import-2026-05-03T15:53:33Z | 21 (1) | 155CC8BC Vet Visit Episode Premise (0.6739) |
| FF0C11DE | Iconoclasmic Video Series | Iconoclasher / Iconoclysm / Iconogasm with Tom McJazz. "When I see shit I don't like, I make a video about it." | 2026-05-03T15:53:33Z | import-2026-05-03T15:53:33Z | 22 (1) | 2942D9B0 Urinal Cake Tagline (0.4235) |

