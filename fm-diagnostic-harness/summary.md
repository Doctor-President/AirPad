# FM Tagging Diagnostic — A1 vs A2

- Run date: 2026-05-09T01:30:45Z
- Seed: 42
- Sample size: 20
- Vocabulary size: 72

## Aggregate

| metric | A1 (free-form + post-filter) | A2 (typed enum) |
|---|---|---|
| errors | 1 | 1 |
| empty-tag results (no error) | 1 | 0 |
| avg post-filter tag count | 3.00 | 3.05 |
| avg latency (ms, success only) | 2657 | 2680 |

## Per-node tag set diffs (post-filter)

| node | title | A1 tags | A2 tags | same? |
|---|---|---|---|---|
| C57169F2 | Diet Coke Psychology | Sociology, Psychology, Cultural Studies | Diet Coke, Sociology, Psychology | **no** |
| 70A66523 | Sometimes a right angle is the wrong angle | Conceptual, Design, Reflective | Conceptual, Reflective | **no** |
| 0A0DB1DA | Episode Premise: Hole to China | Science, Technology, Conceptual, Time Travel | Conceptual, Cosmic, Travel, Time Travel, Idea | **no** |
| 1E9C4DEF | Action Button Reveal | Technology, Design, Attention | Idea, Attention, Control, Design, Reflective | **no** |
| 42B8C8DB | Boomers Dividing and Multiplying | Sociology, Human Rights, Middle-earth | Conceptual, Sociology, History | **no** |
| 3B5584B8 | The Complexity of Morality in Middle-earth | Conceptual, Conflict, Morality | Middle-earth, Morality | **no** |
| 6215BD85 | Mask Dynamics | Conceptual, Attention, Masculinity, Human Rights, Morality | Conceptual, Emotional, Power, Sociology | **no** |
| 18C0ADA0 | Stress Testing Router Classification Limits | Technology | Conceptual, Attention, Control, Technology, Idea | **no** |
| 0638A25E | Vertical Farming Future | (empty) | Food, Technology, Science, Nature | **no** |
| DF6B5E4B | Zoom-Dependent Clustering for Over-Nodes | Conceptual, Design, Technology | Conceptual, Attention, Design | **no** |
| 56C645B8 | Topographic Canvas with Semantic Discovery | Conceptual, Design | Conceptual, Design, Attention | **no** |
| DDC66F15 | Mirror of Truth | Attention, Conceptual, Reflective, Idea | Conceptual, Attention, Technology | **no** |
| 948C90CD | Episode Premise: Lights Out | Conflict, Attention, Dream, Idea | Cosmic, Conflict, Dream, Idea | **no** |
| 09C7E791 | Historical Revisionism in WWII Narratives | Conceptual, Historical Revisionism, Conflict | Historical Revisionism, Idea | **no** |
| DEA2B9DB | Reexamining Meals: Breakfast as a Critical Meal | Conceptual, Food, History | Food, History | **no** |
| 9C8F8D6F | Exploring Hate Faces on TikTok | Attention, Conflict, Emotional, Opinion, Psychology | Emotional, Psychology | **no** |
| 7735A62F | Tomato Recipe | Food, Recipe | Food, Recipe | yes |
| 4B5E9285 | AirPad Concept | Conceptual, Design, Attention, Idea | Conceptual, Design, Creative | **no** |
| FF43DCC8 | Queerness as Self-Expression | Conceptual, Creative, Emotional, Morality, Opinion | Creative, Emotional, Opinion, Morality | **no** |
| E7BCE684 | Creative Storytelling and Technology | (empty) | (empty) | yes |

## A1 raw → drop list (out-of-vocabulary tokens emitted by A1)

- 70A66523 Sometimes a right angle is the wrong angle: Logic
- 18C0ADA0 Stress Testing Router Classification Limits: Development, Innovation
- 0638A25E Vertical Farming Future: Agriculture, Environmental Impact, Food Security
- 56C645B8 Topographic Canvas with Semantic Discovery: Spatial Awareness, Visual Thinking
- DDC66F15 Mirror of Truth: Hypothetical, Thought
