import SwiftUI

/// The "working" ellipsis (the Librarian's "Still adding older items" line, the Map's "Thinking" pill): three dots
/// that fill in sequence.
///
/// Mac perf audit (2026-11-18, measured): on the Mac a `.symbolEffect(… .repeating)` redraws its layer on every
/// display frame, and each of those draws makes the main thread wait for the system's render server. With the
/// Librarian column showing the line, every screen kept the main thread 20–70 % busy at rest (44–62 wake-ups a
/// second) and the Map never came to rest; with the column closed the same screens cost ~0. Measured with the
/// recorder's layer probe: the 11 × 3 pt symbol layer was redrawn ~115 times a second. Stepping the SAME symbol
/// through `variableValue` on a timer did not help (still ~96 redraws a second: the symbol animates between values);
/// a plain still symbol costs 0. So on the Mac the dots are three plain circles that step three times a second
/// (3 small draws a second). iPhone and iPad keep the system effect unchanged. `-MacPerfAB oldellipsis` = as before.
struct WorkingEllipsis: View {
    /// The font size the dots sit beside (the symbol was drawn at this size).
    var size: CGFloat = 12

    var body: some View {
        #if targetEnvironment(macCatalyst)
        if perfAB("oldellipsis") {
            Image(systemName: "ellipsis").symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            let d = (size * 0.22).rounded(.up), gap = max(1, (size * 0.13).rounded())
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.3)) { ctx in
                let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.3) % 4   // 0 = none lit … 3 = all three
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(.foreground).opacity(i < step ? 1 : 0.35).frame(width: d, height: d)
                    }
                }
                .transaction { $0.animation = nil }
            }
            .accessibilityHidden(true)
        }
        #else
        Image(systemName: "ellipsis").symbolEffect(.variableColor.iterative, options: .repeating)
        #endif
    }
}
