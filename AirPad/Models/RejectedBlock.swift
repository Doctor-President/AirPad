import Foundation

/// A block of text that failed the BatchParser quality gate and is held for user review.
/// Stored in UserDefaults so nothing is silently discarded.
struct RejectedBlock: Codable, Identifiable {
    let id: String
    let text: String
    let reason: Reason
    let importTimestamp: String
    let rejectedAt: Date

    enum Reason: String, Codable {
        case heuristic   // caught by fragment-detection heuristics before any model call
        case coherence   // failed Foundation Model "complete standalone idea?" check
    }
}
