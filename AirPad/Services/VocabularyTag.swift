import Foundation
import FoundationModels

/// The user's tag vocabulary as a HARD, shared product constraint — AirPad requires tags drawn
/// from the existing vocabulary regardless of which model produced them (ws-local-model Stage 2).
///
/// - **Foundation Model path:** used as `@Generable`, so guided generation constrains the output to
///   these 72 cases BY CONSTRUCTION. Round 9 measured enum case names as NOT classifier surface
///   (D3 and D4 threw on the identical 8 nodes), so this constraint is free on the FM side.
/// - **Local model path:** the parsed JSON tags are VALIDATED against the SAME enum via
///   `validated(_:)`, which DROPS anything with no exact match (see the drop-not-coerce note there).
///
/// Cases lifted VERBATIM from `fm-diagnostic-harness` (Round 2 A2 / Round 9 D3); do not redefine.
/// `@Generable` needs iOS 26 (like `NodeAIResult` / `ProcessNodeResult`), so the whole type is gated —
/// AirPad's structured lever is iOS-26 for both providers, so validation lives on the iOS-26 side too.
@available(iOS 26.0, *)
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

@available(iOS 26.0, *)
extension VocabularyTag {
    /// Canonical set of valid tag raw values (the vocabulary), for validating free-form tags —
    /// e.g. parsed from a local model's JSON — against the SAME vocabulary the FM path is constrained to.
    static let allowedRawValues: Set<String> = Set(allCases.map(\.rawValue))

    /// Keep only tags that EXACTLY match the vocabulary; **DROP** the rest.
    /// ★ Decision (stated for the arc): no nearest-match. An invented or near-miss tag is a real
    /// product cost — it pollutes the user's vocabulary and mis-clusters — so an unmatched local-model
    /// tag is discarded, never coerced to a neighbour. This mirrors Round 9's "drop anything that
    /// doesn't match" and keeps both paths converging on the exact same tag set.
    static func validated(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { allowedRawValues.contains($0) && seen.insert($0).inserted }
    }
}
