import SwiftUI

/// ★ General ↔ Library mode pill (Brief AH1: was "Private"→General; privacy is a whole-app property, so this axis is
/// named for WHAT the Librarian reads). General = the model's own knowledge (+ the web once a search key exists), no
/// retrieval; Library turns on entry-grounded answering with [n] citations. Legibility (T is colourblind): the state
/// reads by SHAPE + LABEL + ICON, never colour — different SF Symbols (`globe` vs `books.vertical.fill`), different
/// words, and Library adds a stroke + heavier fill so "on" is unmistakable in grayscale. AH4: the icon + label
/// crossfade on toggle (spring; Reduce Motion → instant).
/// live-27 (4b) — one shared view: the Librarian and the Chat view show the same toggle over the same stored setting
/// (`LibrarianState.corpusAware`), so both surfaces route a turn the same way.
struct CorpusModeToggle: View {
    @Environment(\.appBodyFont) private var appFont   // 1.1-A type pass
    let librarian: LibrarianState
    var identifier: String
    /// After a flip (the Librarian's first-use coach-mark).
    var onFlip: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let on = librarian.corpusAware
        Button {
            librarian.pendingWebSearchOffer = nil   // AI5 — a manual mode flip retires any stale offer
            librarian.corpusAware.toggle()   // stored + persisted (didSet → UserDefaults)
            onFlip()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "books.vertical.fill" : "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(on ? "Library" : "General")
                    .font(appFont.font(size: 12, weight: .semibold, relativeTo: .caption1))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(AppearancePalette.ink.opacity(on ? 0.9 : 0.55))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(AppearancePalette.ink.opacity(on ? 0.12 : 0.05))
            )
            .overlay(
                // Stroke ONLY in Library mode — a grayscale-legible shape cue for "on".
                Capsule().strokeBorder(AppearancePalette.ink.opacity(on ? 0.28 : 0), lineWidth: 1)
            )
            .contentShape(Capsule())
            // AH4 — one-shot crossfade of icon + label; Reduce Motion swaps instantly.
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.75), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Library mode" : "General mode")
        .accessibilityHint("General mode — answers from the model; Library mode — reads and cites your entries.")
        .accessibilityIdentifier(identifier)
    }
}
