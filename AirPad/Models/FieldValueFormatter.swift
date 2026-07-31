import Foundation

/// Stage 5.1 — turns a `FieldValue` + its `FieldDefinition` into a display
/// string for the card stat line and the Attributes-section row. Pure (no
/// SwiftUI) so both render sites share one formatter and `FieldValueSelfTest`
/// asserts its output headlessly. Formatting is per-kind, locale-aware, and
/// deliberately PLAIN at Stage 1 — this is correctness, not taste (taste comes
/// when there is something to look at). `rating` (stars) is rendered by the
/// view; this returns the numeric fallback string for it.
enum FieldValueFormatter {

    /// The compact value string. Returns nil for an unfilled value (`value ==
    /// nil`) or an empty text/vocabulary — the caller renders a placeholder or
    /// omits the glyph. When `upperValue` is present (a scalar range), returns
    /// "lower–upper" with an en dash.
    static func display(
        _ value: FieldValue,
        definition: FieldDefinition,
        resolveNodeTitle: (String) -> String? = { _ in nil }
    ) -> String? {
        guard let payload = value.value,
              let lower = string(for: payload, definition: definition, resolveNodeTitle: resolveNodeTitle)
        else { return nil }
        if let upper = value.upperValue,
           let upperStr = string(for: upper, definition: definition, resolveNodeTitle: resolveNodeTitle) {
            return "\(lower)\u{2013}\(upperStr)"   // en dash
        }
        return lower
    }

    /// A single payload → its display string (nil when the value is
    /// semantically empty, e.g. empty text / no vocabulary picks).
    static func string(
        for payload: FieldPayload,
        definition: FieldDefinition,
        resolveNodeTitle: (String) -> String?
    ) -> String? {
        switch payload {
        case .number(let n):
            return numberString(n)
        case .measurement(let amount, let unit):
            return "\(numberString(amount)) \(unit)"
        case .duration(let seconds):
            return durationString(seconds)
        case .date(let date, let hasTime):
            return dateString(date, hasTime: hasTime)
        case .money(let amount, let code):
            return moneyString(amount, currencyCode: code)
        case .rating(let v):
            return "\(v)/\(definition.config.ratingScale ?? 5)"
        case .location(let name, _, _):
            return name.isEmpty ? nil : name
        case .text(let s):
            return s.isEmpty ? nil : s
        case .vocabulary(let valueIDs):
            let labels = valueIDs.compactMap { id in
                definition.config.vocabularyValues?.first { $0.id == id }?.label
            }
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        case .boolean(let b):
            return b ? "Yes" : "No"
        case .url(let s):
            return s.isEmpty ? nil : s
        case .nodeReference(let nodeID):
            return resolveNodeTitle(nodeID)
        }
    }

    // MARK: - Per-kind helpers (locale-aware, plain)

    static func numberString(_ n: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        return f.string(from: n as NSDecimalNumber) ?? "\(n)"
    }

    /// Canonical seconds → flexed display: "45 min", "1 hr 15", "1 hr", "2 hr".
    static func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h) hr \(m)" }
        if h > 0 { return "\(h) hr" }
        return "\(m) min"
    }

    static func dateString(_ date: Date, hasTime: Bool) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = hasTime ? .short : .none
        return f.string(from: date)
    }

    static func moneyString(_ amount: Decimal, currencyCode: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currencyCode
        return f.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}
