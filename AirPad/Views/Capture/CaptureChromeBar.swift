import SwiftUI

/// ONE spacing/size scale for the capture chrome, shared by both surfaces so they
/// cannot drift. Retune here and both move together (T's eye is the spec). Free
/// (not nested in the generic `CaptureChromeBar`, which can't hold static storage).
enum CaptureChromeMetrics {
    /// ★ THE ONE height every element in the bar reads — the primitives pill AND the
    /// Cancel / Delete / Done pills. Not three values that happen to agree: one value
    /// three things derive from, so tops and bottoms stay flush on one baseline.
    static let barHeight: CGFloat = 44
    static let itemSpacing: CGFloat = 8        // between the primitives pill and the action group
    static let groupSpacing: CGFloat = 8       // fixed gap between the Delete and Done pills
    static let primitiveSpacing: CGFloat = 2   // between glyphs inside the primitives pill
    static let hPadding: CGFloat = 14          // bar margin from the screen edges
    static let bottomPadding: CGFloat = 8       // gap below the bar (above the home indicator)
    static let pillHPadding: CGFloat = 14       // Delete/Done inner text padding
    static let primitivesHPadding: CGFloat = 6  // primitives pill inner padding
    /// Breathing room kept BELOW the caret when the keyboard is up (item 2): the
    /// focused line scrolls to this margin above the keyboard, not flush to it.
    static let caretBottomMargin: CGFloat = 28
    /// Primitive glyph tap-frame + symbol, DERIVED from `barHeight` (T: NOT an
    /// independent 40): the frame fills the pill height, the symbol sits inside it
    /// with breathing room.
    static var primitiveWidth: CGFloat { barHeight - 8 }
    static var primitiveGlyphSize: CGFloat { barHeight * 0.46 }
}

/// SHARED capture-chrome bar for BOTH capture surfaces — `QuikCaptureView` and
/// `NodeDetailView`'s capture mode. One component, not two clones.
///
/// ★ CONTAINER RULE: a pill wraps ONLY the additive primitives (waveform · camera ·
/// document · link) — that is the pill's job, grouping the ADD controls. The action
/// pills (Cancel / Done / Delete) are a DIFFERENT class of control (they act on the
/// whole capture, they don't add to it) and stay BARE, outside any container — they
/// are pills themselves and don't need a second one around them. So:
///   • QuikCapture → primitives-pill leading, bare action pills trailing.
///   • Detail capture → NO pill at all (it passes no primitives), just the bare
///     action pills trailing. The container is ABSENT, not empty-and-collapsed.
/// The primitives pill is applied by the CALLER via `.capturePrimitivesContainer()`
/// on its leading content, so this component never wraps an empty leading slot.
struct CaptureChromeBar<Leading: View>: View {
    let hasContent: Bool
    let onDone: () -> Void
    let onDiscard: () -> Void
    /// Surface-specific leading content — QuikCapture's primitives already wrapped in
    /// their pill; the detail surface passes `EmptyView` (→ no container).
    @ViewBuilder var leading: Leading

    @State private var showDeleteConfirmation = false

    private typealias M = CaptureChromeMetrics

    var body: some View {
        HStack(spacing: M.itemSpacing) {
            leading
            Spacer(minLength: M.itemSpacing)
            // Action controls — grouped (Delete beside Done, fixed gap), bare, at the
            // trailing end. Same on both surfaces (the detail bar is this minus its
            // leading slot). Delete is a pill matching Done's shape/height (red
            // `#FF3B30` + white text — the WORD carries it, colour non-load-bearing).
            HStack(spacing: M.groupSpacing) {
                if hasContent {
                    pill(title: "Delete",
                         fill: Color(hexString: "FF3B30"),
                         ink: Color(hexString: "FFFFFF"),
                         action: { showDeleteConfirmation = true })
                        .accessibilityLabel("Delete capture")
                }
                pill(title: hasContent ? "Done" : "Cancel",
                     fill: hasContent ? AppearancePalette.ink : AppearancePalette.ink.opacity(0.14),
                     ink: hasContent ? AppearancePalette.onInk : AppearancePalette.ink,
                     action: { if hasContent { onDone() } else { onDiscard() } })
            }
        }
        .padding(.horizontal, M.hPadding)
        .padding(.bottom, M.bottomPadding)
        .animation(.easeInOut(duration: 0.2), value: hasContent)
        .confirmationDialog("Delete this capture?",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDiscard() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your note and anything you've added will be deleted. This can't be undone.")
        }
    }

    /// A capsule pill at the SHARED `barHeight`; the word is non-compressible so it
    /// always renders in full (`lineLimit(1)` + `fixedSize`).
    private func pill(title: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(ink)
                .padding(.horizontal, M.pillHPadding)
                .frame(height: M.barHeight)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// The primitives-ONLY container. The pill groups the ADDITIVE primitives; the
    /// action pills are a different class and stay bare (see `CaptureChromeBar`).
    /// Muted fill = the SAME token the lever's resting circle and the
    /// Add-to-collection / Add-tag chips use: `AppearancePalette.ink.opacity(0.08)`
    /// (ink = `#232A2E` light / `#FFFFFF` dark → the fill is #232A2E@8% over the warm
    /// off-white page in light, #FFFFFF@8% over the dark page in dark), so all three
    /// stay locked to one source. Height = the shared `barHeight`.
    func capturePrimitivesContainer() -> some View {
        self
            .padding(.horizontal, CaptureChromeMetrics.primitivesHPadding)
            .frame(height: CaptureChromeMetrics.barHeight)
            .background(AppearancePalette.ink.opacity(0.08), in: Capsule())
    }
}

// MARK: - Pinned mount (shared by both surfaces)

private struct CaptureBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Pins `bar` to the bottom of the surface (a `GeometryReader`) and reports its
    /// MEASURED height back through `height`, so the caller can reserve that much
    /// bottom inset on its scroll content — content must never sit under the bar.
    /// Reservation is the CALLER's job (only it knows the keyboard state): reserve
    /// the bar height when the keyboard is DOWN, but NOT when it's up (content already
    /// avoids the keyboard and the bar is behind it — reserving both double-counts).
    ///
    /// ★ Apply to the OUTERMOST view (the `GeometryReader`) so the bar is a SIBLING,
    /// not a descendant. The GeometryReader shrinks under the keyboard (scrolling the
    /// note into view); the bar lives in a FULL-HEIGHT layer that ignores the keyboard
    /// safe area, so it stays docked at the TRUE bottom while the keyboard passes over
    /// it. The FORMAT toolbar (the editor's `inputAccessoryView`) keeps riding the
    /// keyboard, as it should.
    func pinnedCaptureBar<Bar: View>(height: Binding<CGFloat>, @ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(PinnedCaptureBarModifier(bar: bar(), height: height))
    }
}

private struct PinnedCaptureBarModifier<Bar: View>: ViewModifier {
    let bar: Bar
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
            VStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                bar
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: CaptureBarHeightKey.self, value: g.size.height)
                        }
                    )
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)   // ★ THE PIN (full-height ignoring layer)
        }
        .onPreferenceChange(CaptureBarHeightKey.self) { height = $0 }
    }
}
