import Foundation
import FoundationModels

/// Pulled from corpus_index.json tags dict on 2026-05-08 — the 72
/// currently-in-use tag names. Order = sorted alphabetic for stability.
let vocabulary: [String] = [
    "AirPad", "Art", "Attention", "Bank", "Cat", "Comedy", "Conceptual",
    "Conflict", "Constellation", "Control", "Cosmic", "Creative",
    "Cultural Studies", "Darkness", "Design", "Diet Coke", "Dogs",
    "Domestication", "Dream", "Dumb humor", "Emotional", "Etymology",
    "FanLoyalty", "Fear", "Finance", "Fitness", "Food", "Geometry", "Golf",
    "Guidance", "Health", "Historical Revisionism", "History", "Human Rights",
    "Humor", "Hyper-masculinity", "Idea", "Learning", "Manipulation",
    "Masculinity", "Math", "Memory", "Message", "Middle-earth", "Morality",
    "MunicipalPride", "Music", "Nature", "Opinion", "Ownership", "People",
    "Power", "Project", "Psychology", "PublicPolicy", "Recipe", "Reference",
    "Reflective", "Reform", "Religion", "Research", "Science", "Sociology",
    "Sports", "Story", "Team Dynamics", "Technology", "Time Travel", "Travel",
    "Trends", "Washington DC", "Work"
]

/// A2 — hard-typed vocabulary as a Generable enum. Raw String values so the
/// FM schema constrains output to the exact tag literals (with spaces /
/// punctuation preserved), and we can map Generable case → original tag
/// name without an additional normalization step.
@Generable
enum VocabularyTag: String, CaseIterable, Codable {
    case airPad = "AirPad"
    case art = "Art"
    case attention = "Attention"
    case bank = "Bank"
    case cat = "Cat"
    case comedy = "Comedy"
    case conceptual = "Conceptual"
    case conflict = "Conflict"
    case constellation = "Constellation"
    case control = "Control"
    case cosmic = "Cosmic"
    case creative = "Creative"
    case culturalStudies = "Cultural Studies"
    case darkness = "Darkness"
    case design = "Design"
    case dietCoke = "Diet Coke"
    case dogs = "Dogs"
    case domestication = "Domestication"
    case dream = "Dream"
    case dumbHumor = "Dumb humor"
    case emotional = "Emotional"
    case etymology = "Etymology"
    case fanLoyalty = "FanLoyalty"
    case fear = "Fear"
    case finance = "Finance"
    case fitness = "Fitness"
    case food = "Food"
    case geometry = "Geometry"
    case golf = "Golf"
    case guidance = "Guidance"
    case health = "Health"
    case historicalRevisionism = "Historical Revisionism"
    case history = "History"
    case humanRights = "Human Rights"
    case humor = "Humor"
    case hyperMasculinity = "Hyper-masculinity"
    case idea = "Idea"
    case learning = "Learning"
    case manipulation = "Manipulation"
    case masculinity = "Masculinity"
    case math = "Math"
    case memory = "Memory"
    case message = "Message"
    case middleEarth = "Middle-earth"
    case morality = "Morality"
    case municipalPride = "MunicipalPride"
    case music = "Music"
    case nature = "Nature"
    case opinion = "Opinion"
    case ownership = "Ownership"
    case people = "People"
    case power = "Power"
    case project = "Project"
    case psychology = "Psychology"
    case publicPolicy = "PublicPolicy"
    case recipe = "Recipe"
    case reference = "Reference"
    case reflective = "Reflective"
    case reform = "Reform"
    case religion = "Religion"
    case research = "Research"
    case science = "Science"
    case sociology = "Sociology"
    case sports = "Sports"
    case story = "Story"
    case teamDynamics = "Team Dynamics"
    case technology = "Technology"
    case timeTravel = "Time Travel"
    case travel = "Travel"
    case trends = "Trends"
    case washingtonDC = "Washington DC"
    case work = "Work"
}
