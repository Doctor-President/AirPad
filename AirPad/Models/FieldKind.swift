import Foundation

/// Stage 5.1 (atomic fields) — the closed set of field KINDS. This is the
/// expensive-to-extend thing (`ws-atomic-entry-types.md`): the system reasons
/// about a field BY KIND (sort, filter, aggregate); the user reads and names
/// it by the definition's display name (`typed-fields-with-display-names.md`).
///
/// Presets (Cook Time, Serves, Price) are `(display name, kind)` pairs the
/// system ships — Cook Time is `duration` named "Cook time" — NOT cases on
/// this enum, so a user's "Marinade time" (`duration`) and a built-in Cook
/// Time sort and aggregate together. String-backed with snake_case raw values
/// for JSON parity with the existing `NodeItemType` / `NodeItem` CodingKey
/// conventions.
enum FieldKind: String, Codable, Equatable, CaseIterable {
    case number
    case measurement
    case duration
    case date
    case money
    case rating
    case location
    case text
    case vocabulary
    case boolean
    case url
    case nodeReference = "node_reference"
}

extension FieldKind {
    /// The four scalar kinds where a range (an optional second value) is
    /// meaningful. A range is a property of the VALUE (`FieldValue.upperValue`),
    /// gated per-definition by `FieldConfig.rangeEnabled`; this only says which
    /// kinds may offer it at all.
    var supportsRange: Bool {
        switch self {
        case .number, .duration, .measurement, .money:
            return true
        case .date, .rating, .location, .text, .vocabulary, .boolean, .url, .nodeReference:
            return false
        }
    }

    /// Stage 5.2 — human label for the kind picker. The "New Field" section is
    /// the first place a user meets the actual kind vocabulary.
    var pickerName: String {
        switch self {
        case .number:        return "Number"
        case .measurement:   return "Measurement"
        case .duration:      return "Duration"
        case .date:          return "Date"
        case .money:         return "Money"
        case .rating:        return "Rating"
        case .location:      return "Location"
        case .text:          return "Text"
        case .vocabulary:    return "Vocabulary"
        case .boolean:       return "Yes / No"
        case .url:           return "Link"
        case .nodeReference: return "Node reference"
        }
    }

    /// A plain-CONSEQUENCE note for the picker (not a definition), where one
    /// helps the choice — written as consequences per the workstream
    /// (*"won't be sortable"* lands; *"unstructured string"* does not).
    var pickerNote: String? {
        switch self {
        case .text:        return "Free text — won't be sortable or filterable."
        case .vocabulary:  return "Pick from a reusable list — stays sortable and filterable."
        case .measurement: return "You'll choose what it measures next."
        case .boolean:     return "A simple yes or no."
        default:           return nil
        }
    }
}
