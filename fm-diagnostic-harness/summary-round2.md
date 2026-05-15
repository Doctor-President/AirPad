# FM Tagging Diagnostic — Round 2 (A1–A6 side-by-side)

- Run date: 2026-05-09T01:50:51Z
- Seed: 42
- Sample size: 20
- Vocabulary size: 72
- A1, A2 columns sourced from existing results-A1.json / results-A2.json (Round 1 run).
- A5/A6 stage-1 summary is shared between the two variants (single FM call per node, reused).

## Aggregate (A3–A6 only)

| metric | A3 (enum + abstain) | A4 (folksonomy → cosine) | A5 (summary → free-form) | A6 (summary → enum) |
|---|---|---|---|---|
| errors | 1 | 0 | 1 | 1 |
| empty post-filter (no error) | 0 | 0 | 0 | 0 |
| avg post-filter tag count | 2.95 | 4.10 | 3.84 | 4.37 |
| avg total latency (ms, success) | 2887 | 1344 | 3402 | 3657 |

## Per-node post-filter tags — A1 → A6

| node | title | A1 | A2 | A3 | A4 (tier-1) | A5 | A6 |
|---|---|---|---|---|---|---|---|
| C57169F2 | [entry title] | Sociology, Psychology, Cultural Studies | Diet Coke, Sociology, Psychology | Diet Coke, Sociology, Psychology | Diet Coke, Washington DC, Psychology, Sociology, Masculinity | Washington DC, Cultural Studies, Idea | Conceptual, Sociology, PublicPolicy, History, Washington DC |
| 70A66523 | Sometimes a right angle is the wrong angle | Conceptual, Design, Reflective | Conceptual, Reflective | Conceptual, Creative, Geometry | Geometry, Psychology, Etymology, Conceptual, Dream | Conceptual, Idea | Conceptual, Attention, Reflective |
| 0A0DB1DA | Episode Premise: Hole to China | Science, Technology, Conceptual, Time Travel | Conceptual, Cosmic, Travel, Time Travel, Idea | Science, Conceptual, Idea, Time Travel, Middle-earth | Science, Travel, Research, Conceptual, Cosmic | Art, Cosmic, Comedy, Conceptual, Design | Cosmic, Creative, Comedy, Dream, Science |
| 1E9C4DEF | Action Button Reveal | Technology, Design, Attention | Idea, Attention, Control, Design, Reflective | Design, Attention, Idea | Memory, Technology, Guidance | Design, Technology | Creative, Design, Idea, Technology, People |
| 42B8C8DB | Boomers Dividing and Multiplying | Sociology, Human Rights, Middle-earth | Conceptual, Sociology, History | Conceptual, Sociology, History | Manipulation, Trends, Team Dynamics | Sociology, Cultural Studies | Conflict, Cultural Studies, Idea |
| 3B5584B8 | [entry title] | Conceptual, Conflict, Morality | Middle-earth, Morality | Middle-earth, Morality | Emotional, Morality, Comedy, Darkness, Historical Revisionism | Conceptual, Conflict, Morality, Idea, Sociology | Conflict, Morality, Idea |
| 6215BD85 | Mask Dynamics | Conceptual, Attention, Masculinity, Human Rights, Morality | Conceptual, Emotional, Power, Sociology | Conceptual, Emotional | Morality, Health, Guidance, People, Nature | Attention, Conceptual, Conflict, Emotional, Idea | Conceptual, Emotional, Masculinity, Power, Sociology |
| 18C0ADA0 | Stress Testing Router Classification Limits | Technology | Conceptual, Attention, Control, Technology, Idea | Conceptual, Attention, Technology | Manipulation, Washington DC | Conceptual, Creative, Technology, Design, Idea | Attention, Conceptual, Creative, Design, Learning |
| 0638A25E | [entry title] | (empty) | Food, Technology, Science, Nature | Food, Science, Technology | Food, Conflict, Domestication, Manipulation | Food | Food, Conceptual, Design, Science, Technology |
| DF6B5E4B | [entry title] | Conceptual, Design, Technology | Conceptual, Attention, Design | Conceptual, Design, Idea | PublicPolicy | Conceptual, Design, Technology, Idea | Conceptual, Design, Idea, Technology, Trends |
| 56C645B8 | [entry title] | Conceptual, Design | Conceptual, Design, Attention | Conceptual, Design | Fear, Reflective, PublicPolicy, Cosmic, AirPad | Conceptual, Design, Geometry | Art, Conceptual, Design, Geometry, Creative |
| DDC66F15 | [entry title] | Attention, Conceptual, Reflective, Idea | Conceptual, Attention, Technology | Conceptual, Attention, Creative, Control, Reflective | Message, Fitness, Trends, Design, Technology | Attention, Conceptual, Emotional, Reflective, Idea | Conceptual, Attention, Reflective |
| 948C90CD | Episode Premise: Lights Out | Conflict, Attention, Dream, Idea | Cosmic, Conflict, Dream, Idea | Conceptual, Reflective | Comedy, Humor, Idea | Conceptual, Conflict, Darkness, Idea, Story | Conceptual, Attention, Conflict, Darkness, Idea |
| 09C7E791 | [entry title] | Conceptual, Historical Revisionism, Conflict | Historical Revisionism, Idea | Historical Revisionism, Idea | AirPad, History, Cosmic, Power, Morality | Conceptual, Historical Revisionism, Idea, Morality, PublicPolicy | Historical Revisionism, Idea, Conflict, Cultural Studies, Morality |
| DEA2B9DB | Reexamining Meals: Breakfast as a Critical Meal | Conceptual, Food, History | Food, History | Food, Conceptual, History | Food, Domestication, Diet Coke, MunicipalPride | Conceptual, Historical Revisionism, Sociology, Cultural Studies, PublicPolicy | Food, Conceptual, Historical Revisionism, Idea, PublicPolicy |
| 9C8F8D6F | [entry title] | Attention, Conflict, Emotional, Opinion, Psychology | Emotional, Psychology | Emotional, Psychology | AirPad, Fear, Psychology, Humor, Emotional | Attention, Emotional, Psychology, Manipulation, Cultural Studies | Attention, Emotional, Idea, Psychology, Sociology |
| 7735A62F | Tomato Recipe | Food, Recipe | Food, Recipe | Food, Recipe | Diet Coke, Recipe, Food | Food | Recipe |
| 4B5E9285 | AirPad Concept | Conceptual, Design, Attention, Idea | Conceptual, Design, Creative | Conceptual, Design, AirPad | AirPad, Hyper-masculinity, Technology, Reflective | Conceptual, Creative, Design, Idea, Human Rights | Art, Attention, Cosmic, Creative, Emotional |
| FF43DCC8 | Queerness as Self-Expression | Conceptual, Creative, Emotional, Morality, Opinion | Creative, Emotional, Opinion, Morality | Conceptual, Creative, Emotional, Opinion, Power | Fitness, Hyper-masculinity, Conflict, Morality, Food | Art, Attention, Conceptual, Emotional, Idea | Conceptual, Emotional, Idea, People, Power |
| E7BCE684 | Creative Storytelling and Technology | (empty) | (empty) | ERROR | Historical Revisionism, Religion, Research, Cultural Studies, Conflict | ERROR | ERROR |

## A4 detail — folksonomy raw, top cosine match per folksonomy tag

- **C57169F2** [entry title]
    - folksonomy: Diet Coke, Washington DC, high achieving, Psychology, Sociology, Caffeine, Motivation, Lifestyle
    - matches: Diet Coke→Diet Coke(1.00), Washington DC→Washington DC(1.00), high achieving→Emotional(0.37), Psychology→Psychology(1.00), Sociology→Sociology(1.00), Caffeine→Food(0.45), Motivation→Masculinity(0.60)
    - tier-1: Diet Coke, Washington DC, Psychology, Sociology, Masculinity
- **70A66523** Sometimes a right angle is the wrong angle
    - folksonomy: angle, geometry, mathematics, right angle, perspective, conceptual, thought experiment
    - matches: angle→Trends(0.35), geometry→Geometry(1.00), mathematics→Psychology(0.70), right angle→Message(0.33), perspective→Etymology(0.51), conceptual→Conceptual(1.00), thought experiment→Dream(0.53)
    - tier-1: Geometry, Psychology, Etymology, Conceptual, Dream
- **0A0DB1DA** Episode Premise: Hole to China
    - folksonomy: science fiction, space, travel, adventure, exploration, conceptual, futuristic, epic
    - matches: science fiction→Science(0.63), space→Power(0.44), travel→Travel(1.00), adventure→Comedy(0.45), exploration→Research(0.58), conceptual→Conceptual(1.00), futuristic→Conceptual(0.45), epic→Cosmic(0.60)
    - tier-1: Science, Travel, Research, Conceptual, Cosmic
- **1E9C4DEF** Action Button Reveal
    - folksonomy: action, button, reveal, setup, capture, device, accessibility, feature
    - matches: action→Conflict(0.46), button→Message(0.42), reveal→Message(0.44), setup→Memory(0.52), capture→Manipulation(0.44), device→Technology(0.64), accessibility→Guidance(0.58), feature→Reference(0.44)
    - tier-1: Memory, Technology, Guidance
- **42B8C8DB** Boomers Dividing and Multiplying
    - folksonomy: boomers, generation, multiply, divide, aging, population trends, generational dynamics
    - matches: boomers→Dogs(0.36), generation→Manipulation(0.44), multiply→Manipulation(0.51), divide→Conflict(0.41), aging→Fitness(0.48), population trends→Trends(0.74), generational dynamics→Team Dynamics(0.65)
    - tier-1: Manipulation, Trends, Team Dynamics
- **3B5584B8** [entry title]
    - folksonomy: Lord of the Rings, Good vs Evil, Moral Complexity, Black and White, Epic Fantasy, Philosophical Themes, Darkness, Contemporary Relevance
    - matches: Lord of the Rings→Time Travel(0.39), Good vs Evil→Emotional(0.51), Moral Complexity→Morality(0.68), Black and White→Cosmic(0.41), Epic Fantasy→Comedy(0.62), Philosophical Themes→Morality(0.64), Darkness→Darkness(1.00), Contemporary Relevance→Historical Revisionism(0.54)
    - tier-1: Emotional, Morality, Comedy, Darkness, Historical Revisionism
- **6215BD85** Mask Dynamics
    - folksonomy: mask, behavior, social, authenticity, human, nature, multitudes, psychology
    - matches: mask→Cat(0.47), behavior→Morality(0.57), social→Health(0.53), authenticity→Guidance(0.63), human→People(0.52), nature→Nature(1.00)
    - tier-1: Morality, Health, Guidance, People, Nature
- **18C0ADA0** Stress Testing Router Classification Limits
    - folksonomy: router stress testing, classification limits, needs review, quarantine queue, silently dropped
    - matches: router stress testing→Manipulation(0.55), classification limits→Manipulation(0.48), needs review→Message(0.49), quarantine queue→Washington DC(0.53), silently dropped→Manipulation(0.33)
    - tier-1: Manipulation, Washington DC
- **0638A25E** [entry title]
    - folksonomy: vertical farming, food production, climate change, agriculture, water recycling, controlled environments, yield maximization, pest resistance, biodiversity loss
    - matches: vertical farming→Domestication(0.49), food production→Food(0.68), climate change→Conflict(0.58), agriculture→Domestication(0.54), water recycling→Domestication(0.52), controlled environments→People(0.47), yield maximization→Manipulation(0.58), pest resistance→Domestication(0.63), biodiversity loss→Domestication(0.61)
    - tier-1: Food, Conflict, Domestication, Manipulation
- **DF6B5E4B** [entry title]
    - folksonomy: over-nodes, zoom-dependent clustering, frosted vessel, luminous interior, functional necessity, corpus, navigable threshold, hierarchy
    - matches: over-nodes→Hyper-masculinity(0.38), zoom-dependent clustering→Manipulation(0.49), frosted vessel→Time Travel(0.43), luminous interior→Diet Coke(0.37), functional necessity→PublicPolicy(0.53), corpus→Geometry(0.39), navigable threshold→Time Travel(0.37), hierarchy→PublicPolicy(0.52)
    - tier-1: PublicPolicy
- **56C645B8** [entry title]
    - folksonomy: density, tension, dramatic, size, hierarchy, topographic, canvas, displaced, nodes, color, bleed, semantic, cluster, thread, discovery, surface
    - matches: density→Manipulation(0.43), tension→Fear(0.60), dramatic→Reflective(0.58), size→Memory(0.45), hierarchy→PublicPolicy(0.52), topographic→Cosmic(0.52), canvas→Art(0.40), displaced→AirPad(0.44), nodes→Message(0.40), color→Etymology(0.50), bleed→Fear(0.41), semantic→PublicPolicy(0.52), cluster→AirPad(0.50)
    - tier-1: Fear, Reflective, PublicPolicy, Cosmic, AirPad
- **DDC66F15** [entry title]
    - folksonomy: corpus, mirror, honesty, uncomfortable, patterns, foundation, model, on-device, retrieval, api, opt-in, synthesis, reflection, prompts, invitation
    - matches: corpus→Geometry(0.39), mirror→Message(0.57), honesty→Fitness(0.66), uncomfortable→Emotional(0.47), patterns→Trends(0.64), foundation→Design(0.50), model→Technology(0.57)
    - tier-1: Message, Fitness, Trends, Design, Technology
- **948C90CD** Episode Premise: Lights Out
    - folksonomy: lights out, mystery, thriller, suspense, episode, premise, narrative, drama
    - matches: lights out→Reflective(0.42), mystery→Comedy(0.54), thriller→Comedy(0.67), suspense→Humor(0.59), episode→Story(0.45), premise→Idea(0.63), narrative→Humor(0.70), drama→Comedy(0.74)
    - tier-1: Comedy, Humor, Idea
- **09C7E791** [entry title]
    - folksonomy: worldwar2, history, evil, power, dominant, righteous, imperialism
    - matches: worldwar2→AirPad(0.55), history→History(1.00), evil→Cosmic(0.62), power→Power(1.00), dominant→Cosmic(0.32), righteous→Cosmic(0.54), imperialism→Morality(0.64)
    - tier-1: AirPad, History, Cosmic, Power, Morality
- **DEA2B9DB** Reexamining Meals: Breakfast as a Critical Meal
    - folksonomy: breakfast, meals, foodindustry, diet, nutrition, culturalhistory, supper, dinner
    - matches: breakfast→Math(0.50), meals→Food(0.59), foodindustry→Domestication(0.54), diet→Diet Coke(0.73), nutrition→Food(0.60), culturalhistory→MunicipalPride(0.53), supper→Darkness(0.46), dinner→Darkness(0.39)
    - tier-1: Food, Domestication, Diet Coke, MunicipalPride
- **9C8F8D6F** [entry title]
    - folksonomy: TikTok, hate face, social media, psychology, demeanor, facial expressions, resting bitch face, emotional reactions, online behavior
    - matches: TikTok→AirPad(0.63), hate face→Fear(0.54), social media→Health(0.46), psychology→Psychology(1.00), demeanor→Humor(0.60), facial expressions→Masculinity(0.50), resting bitch face→Dumb humor(0.44), emotional reactions→Emotional(0.66)
    - tier-1: AirPad, Fear, Psychology, Humor, Emotional
- **7735A62F** Tomato Recipe
    - folksonomy: plum tomatoes, large tomatoes, tomato recipe, vegetable dish, cooking ingredient
    - matches: plum tomatoes→Diet Coke(0.51), large tomatoes→Diet Coke(0.41), tomato recipe→Recipe(0.72), vegetable dish→Food(0.65), cooking ingredient→Food(0.57)
    - tier-1: Diet Coke, Recipe, Food
- **4B5E9285** AirPad [entry title]: AirPad, Action Button, first-time experience, layer, app, physical proof, introduction
    - matches: AirPad→AirPad(1.00), Action Button→Message(0.43), first-time experience→Hyper-masculinity(0.54), layer→AirPad(0.47), app→Technology(0.55), physical proof→Reflective(0.55), introduction→Design(0.43)
    - tier-1: AirPad, Hyper-masculinity, Technology, Reflective
- **FF43DCC8** Queerness as Self-Expression
    - folksonomy: queerness, self-expression, autonomy, identity, lifestyle, personal, freedom, terms
    - matches: queerness→Fitness(0.64), self-expression→Hyper-masculinity(0.52), autonomy→Conflict(0.52), identity→Morality(0.54), lifestyle→Food(0.61)
    - tier-1: Fitness, Hyper-masculinity, Conflict, Morality, Food
- **E7BCE684** Creative Storytelling and Technology
    - folksonomy: controversial, gen-z, population, social-issue, discussion, cultural-trend, debate, society
    - matches: controversial→Historical Revisionism(0.53), gen-z→Washington DC(0.48), population→Religion(0.51), social-issue→PublicPolicy(0.44), discussion→Research(0.50), cultural-trend→Cultural Studies(0.58), debate→Conflict(0.55)
    - tier-1: Historical Revisionism, Religion, Research, Cultural Studies, Conflict

## A5/A6 stage-1 summary text (substrate for A5+A6 stage-2)

- **C57169F2** [entry title]: Explores the psychological and sociological connections between Diet Coke consumption and high-achieving individuals in Washington DC.
- **70A66523** Sometimes a right angle is the wrong angle: The idea explores the concept of perspective and context, suggesting that what seems correct or logical may not always be applicable in all situations.
- **0A0DB1DA** Episode Premise: Hole to China: A whimsical journey through dimensions, blending humor, creativity, and cosmic exploration.
- **1E9C4DEF** Action Button Reveal: An innovative feature that allows users to capture and store things without needing an app setup, emphasizing convenience and accessibility.
- **42B8C8DB** Boomers Dividing and Multiplying: This idea explores the demographic phenomenon where baby boomers are experiencing both division (perhaps due to generational or cultural clashes) and multiplication (possibly through new family units or social networks).
- **3B5584B8** [entry title]: The idea explores how the dichotomy of good versus evil has persisted, critiquing societal tendencies to oversimplify morality and how this complexity allows darkness to gain traction.
- **6215BD85** Mask Dynamics: The idea explores how individuals wear different masks based on context, questioning if this is inauthentic or natural.
- **18C0ADA0** Stress Testing Router Classification Limits: This idea involves deliberately pushing a router's classification capabilities to their limits, ensuring any failures are logged and reviewed.
- **0638A25E** [entry title]: Vertical farming presents a promising solution for food production in volatile climates but raises concerns about plant resistance and pest management.
- **DF6B5E4B** [entry title]: The idea explores the concept of clustering based on zoom functionality within a navigable framework, suggesting a shift from hierarchical structures to functional necessity.
- **56C645B8** [entry title]: The idea revolves around dramatic size hierarchies on a topographic canvas and exploring semantic connections through color bleeding and discovery.
- **DDC66F15** [entry title]: The idea centers on using a foundation model as a reflective mirror, prompting users to see uncomfortable truths rather than flattering ones.
- **948C90CD** Episode Premise: Lights Out: An enigmatic premise involving sudden darkness that sparks curiosity and potential conflict or transformation.
- **09C7E791** [entry title]: The narrative of WWII is reframed to highlight how the evil empire manipulated history to portray itself as righteous and dominant.
- **DEA2B9DB** Reexamining Meals: Breakfast as a Critical Meal: The concept that breakfast was historically overlooked and may have been created by the food industry to promote a new routine.
- **9C8F8D6F** [entry title]: Examines the psychological basis of 'hate face' displays on social media, exploring whether such expressions are reflective of true emotions or learned behaviors.
- **7735A62F** Tomato Recipe: A recipe for using 1 1/2 pounds of large plum tomatoes.
- **4B5E9285** AirPad Concept: AirPad is more than just an app; it embodies a transformative experience where the first-time introduction is pivotal.
- **FF43DCC8** Queerness as Self-Expression: Queerness embodies living life according to one's own terms, emphasizing personal freedom and autonomy.
- **E7BCE684** Creative Storytelling and Technology: ERROR — GenerationError: guardrailViolation(FoundationModels.LanguageModelSession.GenerationError.Context(debugDescription: "May contain unsafe content", underlyingErrors: []))

