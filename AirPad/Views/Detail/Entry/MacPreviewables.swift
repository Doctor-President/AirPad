#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

// Sweep 2b · 4.2 — "a subtle 'Space opens this' highlight" (decisions.md 2026-11-22, T: yes): only what Space can open
// gets it — photos and documents (links are out for now). A soft tint + a hairline outline, ~0.1 s fade, no motion
// (no fade either under Reduce Motion); after the pointer rests ~0.5 s a small ␣ keycap hint, only until Space has
// been used a few times (the highlight itself stays). The Mac only; the iPhone keeps long press.
// Not here yet: the same highlight for KEYBOARD focus (Tab / arrows onto an item) — that needs the attachments to be
// focusable, which is 4.1's focus work (reproduced red first in T's focus state).

/// The ␣ hint shows until Space has opened something this many times (app preference, not the library).
enum MacSpaceHint {
    static let usesKey = "mac.spaceHint.uses"
    static let showUntil = 3
    static var shouldShow: Bool { UserDefaults.standard.integer(forKey: usesKey) < showUntil }
    static func noteUsed() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: usesKey) + 1, forKey: usesKey)
    }
}

/// The highlight. Ink-derived (the palette's own ink, no new colour): tint ink × 0.06, hairline ink × 0.30.
struct MacSpaceHighlight: ViewModifier {
    let cornerRadius: CGFloat
    /// What the proof log calls it ("photo <id>", "document <id>"): kinds and ids only.
    let probe: String
    let onHoverChange: (Bool) -> Void
    @State private var hovering = false
    @State private var showHint = false
    @State private var rest: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppearancePalette.ink.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(AppearancePalette.ink.opacity(0.30), lineWidth: 1 / max(displayScale, 1)))
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottomTrailing) {
                if showHint { MacSpaceKeycap().padding(6).transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: showHint)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !hovering {
                        hovering = true
                        onHoverChange(true)
                        MacProofLog.note("4.2", "highlight on \(probe)")
                    }
                    guard !showHint else { return }
                    rest?.cancel()   // the hint waits for the pointer to REST ~0.5 s
                    rest = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled, hovering, MacSpaceHint.shouldShow else { return }
                        showHint = true
                        MacProofLog.note("4.2", "keycap hint \(probe)")
                    }
                case .ended:
                    rest?.cancel(); rest = nil
                    guard hovering else { return }
                    hovering = false; showHint = false
                    onHoverChange(false)
                    MacProofLog.note("4.2", "highlight off \(probe)")
                }
            }
            .onDisappear { rest?.cancel(); rest = nil }
    }
}

/// The small ␣ keycap.
struct MacSpaceKeycap: View {
    var body: some View {
        Text("␣")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(AppearancePalette.ink.opacity(0.75))
            .frame(minWidth: 26, minHeight: 17)
            .background(AppearancePalette.bgElevated.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AppearancePalette.ink.opacity(0.25), lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 4.2 — the "Space opens this" highlight + ␣ hint, reporting hover changes (the keys hang on them).
    func macSpaceHighlight(cornerRadius: CGFloat, probe: String, onHoverChange: @escaping (Bool) -> Void) -> some View {
        modifier(MacSpaceHighlight(cornerRadius: cornerRadius, probe: probe, onHoverChange: onHoverChange))
    }
}

// MARK: - Photos: the highlight and Space

/// A gallery / single photo on the Mac: the highlight, and Space opens what a click opens. Videos: unchanged.
struct MacPhotoActionsModifier: ViewModifier {
    let galleryItem: GalleryItem
    let cornerRadius: CGFloat
    let open: () -> Void

    func body(content: Content) -> some View {
        if galleryItem.mediaType == .image {
            content
                .macSpaceHighlight(cornerRadius: cornerRadius, probe: "photo \(galleryItem.id)") { on in
                    MacDocumentKeys.hover(galleryItem.id, .init(quickLook: {
                        MacSpaceHint.noteUsed()
                        MacProofLog.note("4.2", "space opens photo \(galleryItem.id)")
                        open()
                    }, open: {}, reveal: {}), on)
                }
                .onDisappear { MacDocumentKeys.clear(galleryItem.id) }
        } else {
            content
        }
    }
}

extension View {
    func macPhotoActions(_ galleryItem: GalleryItem, cornerRadius: CGFloat, open: @escaping () -> Void) -> some View {
        modifier(MacPhotoActionsModifier(galleryItem: galleryItem, cornerRadius: cornerRadius, open: open))
    }
}
#endif
