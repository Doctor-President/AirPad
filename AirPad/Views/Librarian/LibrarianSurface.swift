import SwiftUI
import AVFoundation
import FloatingPanel

/// Librarian surface — full Librarian chrome rendered inside the
/// in-layout FloatingPanel mounted at `ContentView` root. Body content
/// branches on the panel's live detent (peek → whisper / pill content,
/// half/full → full chrome). The pre-Move-2 morphing-pill `surfaceMode`
/// and `isSystemSheet` brains are gone — the panel detent is the single
/// source of truth.
///
/// Retrieval rows hand off navigation via `router.pendingNodeNavigationID`
/// so the host NavigationStack (CanvasView / NodeListView) owns the
/// detail-view push — mirroring the capture-overlay pattern.
struct LibrarianSurface: View {

    /// Scope of the host surface this Librarian is mounted on (Corpus
    /// canvas, Journal canvas, or a specific collection canvas/list).
    /// Used to seed `LibrarianState.selectedScope` on first appear in a
    /// new host so the Librarian defaults to the slice the user is
    /// already looking at.
    let hostScope: CanvasScope

    /// FloatingPanel state observer and proxy, supplied by the panel
    /// mount in `ContentView.floatingPanel { proxy in ... }`. The model
    /// is the detent SSOT (body content reads `panelModel.state`);
    /// the proxy is the channel for `.floatingPanelScrollTracking` on
    /// inner scrollables so the panel's drag and the scroll content
    /// don't move under the same finger.
    @ObservedObject var panelModel: LibrarianPanelStateModel
    let proxy: FloatingPanelProxy

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var showModeDropdown = false
    @State private var presentedCitation: PresentedCitation? = nil
    @State private var showEndDialog = false
    @State private var isSavingSession = false
    @State private var researchExportCopied = false
    @FocusState private var isInputFocused: Bool
    /// Focus state for the persistent search field. Kept separate from
    /// `isInputFocused` so each field's own promote-on-focus
    /// `.onChange` fires from its own state, and the lifted Done
    /// (Move 2 fix-pass B) can resign either without guessing which
    /// is live.
    @FocusState private var isSearchFocused: Bool

    /// Focus-driven Solar Flare accent. Mirrors which field is currently
    /// focused (Search → Mango #E8820A, Ask → Klein #1B59C2, neither →
    /// nil) so the panel's edge-glow layer can cross-fade to the
    /// focused field's hue. The field-glow halos read their own
    /// per-field visibility (isSearchFocused / isInputFocused) and
    /// don't consume this property — it exists purely for the panel
    /// edge-glow's color crossfade. Updated inside `withAnimation` so
    /// the cross-fade is centralized; gated on `accessibilityReduceMotion`.
    @State private var activeAccent: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(SolarFlareTuningKey.bloomOn) private var sfBloomOn: Bool = SolarFlareTuningDefaults.bloomOn

    // Ask-specific outer-pass overrides for `SolarFlareFieldGlow` —
    // surfaced here so the call site in `expandedChrome` can pass them
    // straight through. Search uses the shared `sf.fieldGlow*` defaults
    // (passes nil for these). See `SolarFlareTuningKey.askGlow*`.
    @AppStorage(SolarFlareTuningKey.askGlowWidth) private var askGlowWidth: Double = SolarFlareTuningDefaults.askGlowWidth
    @AppStorage(SolarFlareTuningKey.askGlowBlur) private var askGlowBlur: Double = SolarFlareTuningDefaults.askGlowBlur
    @AppStorage(SolarFlareTuningKey.askGlowOpacity) private var askGlowOpacity: Double = SolarFlareTuningDefaults.askGlowOpacity

    // Peek-pill masked LIVE color flare — replaces the flat dark inner
    // fill at peek with the prismatic mesh clipped by a hand-painted
    // grayscale PNG ("PeekPillMask") that carries the falloff. Driven by
    // `sf.peekFlare*` knobs in the tuner; gates are read at the
    // morphingField mount site so the flare fades as the field grows
    // past peek.
    @AppStorage(SolarFlareTuningKey.peekFlareOn) private var sfPeekFlareOn: Bool = SolarFlareTuningDefaults.peekFlareOn
    @AppStorage(SolarFlareTuningKey.peekFlarePalette) private var sfPeekFlarePaletteRaw: String = SolarFlareTuningDefaults.peekFlarePalette
    @AppStorage(SolarFlareTuningKey.peekFlareStrength) private var sfPeekFlareStrength: Double = SolarFlareTuningDefaults.peekFlareStrength
    @AppStorage(SolarFlareTuningKey.peekFlareDesat) private var sfPeekFlareDesat: Double = SolarFlareTuningDefaults.peekFlareDesat
    @AppStorage(SolarFlareTuningKey.peekFlareMaskOpacity) private var sfPeekFlareMaskOpacity: Double = SolarFlareTuningDefaults.peekFlareMaskOpacity
    @AppStorage(SolarFlareTuningKey.peekFlareColorA) private var sfPeekFlareColorARaw: String = SolarFlareTuningDefaults.peekFlareColorA
    @AppStorage(SolarFlareTuningKey.peekFlareColorB) private var sfPeekFlareColorBRaw: String = SolarFlareTuningDefaults.peekFlareColorB

    /// Live keyboard height, observed via UIResponder notifications.
    /// Drives in-content layout (the input row rides above the keyboard,
    /// the transcript stays readable, the dismiss-keyboard affordance
    /// in `inputRow` shows). The panel's frame is owned by FloatingPanel
    /// — this height never moves the panel detent.
    @State private var keyboardHeight: CGFloat = 0

    @State private var dictation = LiveDictationService.shared
    @State private var speech = SpeechSynthesisService.shared

    /// Identifiable wrapper so `.sheet(item:)` re-presents when the user
    /// taps a different chip without dismissing first. Carries the
    /// full citation list so the sheet can compute its bracket indices
    /// against the same numbering the model saw.
    private struct PresentedCitation: Identifiable {
        let nodeID: String
        let citations: [BlockMatch]
        var id: String { nodeID }
    }

    private var activeWhispers: [String] {
        store.ghostQuerySuggestions
    }

    private var displayText: String {
        guard !activeWhispers.isEmpty else { return "" }
        return activeWhispers[currentWhisperIndex % activeWhispers.count]
    }

    var body: some View {
        @Bindable var librarian = router.librarian
        let p = panelModel.peekProgress
        // Staged born-in chrome opacity. Stays at 0 until p=0.5 so the
        // chrome never sits full-size behind the pill at peek; ramps
        // 0→1 across p=0.5→1.0 — Maps cadence (field grows first,
        // chrome populates second).
        let chromeOpacity = max(0, (p - 0.5) / 0.5)

        // GeometryReader exposes the LIVE surface size, which under
        // FloatingPanel's `.fitToBounds` re-fits per detent and grows
        // continuously during drag. The morphing field positions itself
        // against this live size so the field rides the panel's height
        // change as p climbs from 0→1.
        GeometryReader { geo in
            ZStack {
                // Panel material — Solar Flare layered look (tuner-driven
                // base + dark tint + optional rotating prismatic edge).
                // Tied to `chromeOpacity` so the peek posture shows only
                // the morphing field's Liquid Glass; the panel-wide
                // material rises with the chrome. The -150pt bottom
                // buffer + edge-vs-fill split live inside
                // `SolarFlareMaterial`. Drag-gate flips off the rotating
                // edge during finger-drag to keep the live motion cheap.
                SolarFlareMaterial(isDragging: panelModel.isDragging,
                                   activeAccent: activeAccent)
                    .opacity(chromeOpacity)
                    .allowsHitTesting(false)

                // Born-in chrome. Header + chips + transcript/results
                // + input row + footer. The search field is NOT in here
                // — it's the morphing field overlaid on top, which lands
                // in the chrome's reserved slot at p=1. Hidden at peek
                // via `chromeOpacity`; heavy subtrees inside are perf-
                // gated on p>0.4 so transcript/results don't render
                // while the panel is still at peek.
                expandedChrome(librarian: librarian, p: p)
                    .opacity(chromeOpacity)
                    .allowsHitTesting(chromeOpacity > 0.5)

                // THE morphing field. Single view that is both the peek
                // pill and the expanded search field; never swapped,
                // only its frame / position / corner interpolate against
                // p. Position uses `geo.size` so the field tracks the
                // panel's live height. At p=0 it's the baked Maps pill
                // (340 × 64, corner 45, 21pt above safe area). At p=1
                // it's a full-width rounded field (~52pt tall, corner
                // 16) just below the chrome's header.
                morphingField(geo: geo, librarian: librarian, p: p)
            }
        }
        .onAppear {
            startWhisperCycle()
            seedScopeFromHostIfNeeded(librarian: librarian)
        }
        .onChange(of: hostScope) { _, _ in
            seedScopeFromHostIfNeeded(librarian: librarian)
        }
        .onChange(of: panelModel.state) { _, newState in
            // The keyboard belongs only at .full (promote-on-focus).
            // Any exit — flick to half, drop to peek, duck to hidden —
            // tears it down. Both @FocusState bindings get cleared, and
            // the blunt resignFirstResponder catches cross-boundary
            // cases where @FocusState alone has missed.
            if newState != .full {
                isInputFocused = false
                isSearchFocused = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: isInputFocused) { _, focused in
            // Promote-on-focus: never type at a detent shorter than
            // full. Apple sheet pattern, also resolves the keyboard
            // probe's half-panel keyboard-composition defect (Round 2)
            // — at full there is no short-gap conflict to break the
            // keyboard's presentation.
            if focused {
                panelModel.expandToFull(animated: true)
            }
            updateActiveAccent()
        }
        .onChange(of: isSearchFocused) { _, focused in
            // Mirror the chat input's promote-on-focus for the search
            // field. Move 2 fix-pass B: the search TextField was
            // previously unbound, so focusing it left the panel at
            // `.half` and the keyboard buried the field.
            if focused {
                panelModel.expandToFull(animated: true)
            }
            updateActiveAccent()
        }
        .sheet(item: $presentedCitation) { context in
            CitationSheet(
                nodeID: context.nodeID,
                allCitations: context.citations,
                onOpenNote: { router.pendingNodeNavigationID = context.nodeID }
            )
            .environment(store)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = frame.height
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = 0
            }
        }
    }

    /// Surface corner radius — unified at 39pt so the peek pill arc
    /// reads as concentric with the 38pt mode icon ring and the half /
    /// full chrome carries the same arc rather than flattening.
    private var surfaceCornerRadius: CGFloat { 39 }

    /// Top-edge drag grabber. Live-tracks vertical drag: the surface
    /// height follows the finger between detents, with a light haptic
    /// pulse at each posture boundary crossed. On release the surface
    /// snaps to the nearest detent and the live offset is animated
    /// back to zero in the same spring as the mode change.
    @ViewBuilder
    private func dragGrabber(librarian: LibrarianState) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 38, height: 5)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    // MARK: - Morphing field (single-tree morph)

    /// THE search field — exists at all progress, never swapped. At p=0
    /// it draws as the baked Maps pill (340 × 64, corner 45, two-layer
    /// glass + darkened inset) sitting 21pt above the panel's bottom
    /// edge. At p=1 it sits full-width (surface − 28pt margins) just
    /// below the chrome header, corner relaxed to 16, inner inset
    /// collapsed so the field reads as a single rounded rectangle. The
    /// frame, position, and corner radius all interpolate continuously
    /// against `p` — this is what gives the morph its "single object
    /// growing" feel rather than two views crossfading.
    ///
    /// `geo` is the live surface geometry from `body`'s `GeometryReader`;
    /// under `.fitToBounds` the surface height continuously tracks the
    /// drag, so positioning against `geo.size.height` keeps the field
    /// anchored to the bottom-edge gap at peek and to the top-edge
    /// header gap at expanded.
    @ViewBuilder
    private func morphingField(geo: GeometryProxy, librarian: LibrarianState, p: CGFloat) -> some View {
        // Frame / corner interpolation. Values at p=0 are the baked
        // peek pill (Maps anatomy); values at p=1 are the full-width
        // expanded search field that the chrome's reserved slot expects.
        let peekW: CGFloat = 340
        let expandedW = max(0, geo.size.width - 28)
        let fieldW = lerp(peekW, expandedW, p)

        let peekH: CGFloat = 64
        let expandedH: CGFloat = 52
        let fieldH = lerp(peekH, expandedH, p)

        // Outer corner tracks half the field height so the shape stays
        // a full capsule at every interpolation step (32 → 26). Earlier
        // pass relaxed toward 16 and read as a squarish box at p=1;
        // half-height is the cleanest capsule across the morph.
        let outerCorner = fieldH / 2
        let outerShape = RoundedRectangle(cornerRadius: outerCorner, style: .continuous)

        // Y-position interpolation. Peek anchor: 21pt above the panel
        // bottom (so the field's bottom edge sits at geo.height − 21).
        // Expanded anchor: anchors a few points inside the header's
        // bottom-padding band so the Search field sits snug to the
        // chevron (chevron bottom ≈ y=46; field top at y=54 with this
        // anchor → ~8pt gap). The header ZStack itself runs ~60pt tall,
        // but the bottom 14pt is empty padding the field can ride into
        // without colliding with chevron/grabber visuals.
        let peekCenterY = geo.size.height - 21 - peekH / 2
        let expandedCenterY: CGFloat = 54 + expandedH / 2
        let centerY = lerp(peekCenterY, expandedCenterY, p)

        // Mango identity (#E8820A). Caret + icons + (later, gradient
        // peek text) all read against this hue. At p=0 icons are dim
        // (0.66) so the field reads like the baked Maps pill; at p=1
        // they hit full Mango so the field reads as Search clearly.
        let mango = Color(hexString: "E8820A")
        let iconOpacity = lerpD(0.66, 1.0, p)
        // Within-family top→bottom gradient: amber lifted top, mango
        // grounded bottom. Reads richer than a flat fill while staying
        // inside the Mango family, paired with the Klein/cyan grad on
        // the Ask icons so the two fields share treatment.
        let mangoGrad = LinearGradient(
            colors: [Color(hexString: "F2A93B"), Color(hexString: "E8820A")],
            startPoint: .top,
            endPoint: .bottom
        )

        ZStack {
            // Peek flare on the OUTER pill body. Color feathers at the
            // perimeter via the mask; masked-black center supplies the dark.
            // Sits over the glass (PeekGlassBackground modifier below) and
            // under the field content. Fades out as the field grows past peek.
            if sfPeekFlareOn {
                let flareFade = max(0, min(1, Double((p - 0.5) / 0.5)))
                let cA = (SolarFlareNamedColor(rawValue: sfPeekFlareColorARaw) ?? .coral).color
                let cB = (SolarFlareNamedColor(rawValue: sfPeekFlareColorBRaw) ?? .indigo).color
                SolarFlarePeekFlare(
                    colorA: cA, colorB: cB,
                    desaturate: sfPeekFlareDesat,
                    strength: sfPeekFlareStrength,
                    maskOpacity: sfPeekFlareMaskOpacity
                )
                .opacity(1 - flareFade)
                .clipShape(outerShape)
                .allowsHitTesting(false)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(mangoGrad)
                    .opacity(iconOpacity)
                // The real Search TextField — binds to the same
                // `librarian.searchText` that drives instant MATCHES /
                // RELATED. Gated on `p > 0.5` so at peek the whole pill
                // takes the tap (to expand); once expanded the field
                // owns its own taps and the keyboard comes up via
                // `isSearchFocused`'s promote-on-focus.
                TextField("Search", text: Binding(
                    get: { librarian.searchText },
                    set: { librarian.searchText = $0 }
                ))
                    .focused($isSearchFocused)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .tint(mango)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .allowsHitTesting(p > 0.5)
                // Trailing slot: × and stop coexist during dictation so
                // the user can clear without losing the stop control.
                // × left, mic/stop right. Peek-gated so the pill at
                // peek doesn't show a clear before the keyboard is up.
                let isHot = dictation.isListening && dictation.activeToken == "search"
                let hasText = !librarian.searchText.isEmpty && p > 0.5
                HStack(spacing: 8) {
                    if hasText {
                        Button {
                            librarian.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                    if isHot || !hasText {
                        Button {
                            dictation.toggle(
                                token: "search",
                                baseline: librarian.searchText,
                                onUpdate: { librarian.searchText = $0 }
                            )
                        } label: {
                            Image(systemName: isHot ? "stop.fill" : "mic.fill")
                                .font(.system(size: 19))
                                .foregroundStyle(mangoGrad)
                                .opacity(iconOpacity)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(p > 0.5)
                        .accessibilityLabel(isHot ? "Stop dictation" : "Dictate search")
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: fieldH)
        }
        .frame(width: fieldW, height: fieldH)
        // Whole-capsule tap target — single-tap focuses Search from
        // anywhere on the pill (icons, padded gaps, the empty trailing
        // area), not just the TextField's text region. Gated to
        // expanded so it doesn't fight the peek expand-overlay below;
        // at peek, the overlay catches the tap and expandToHalf
        // dispatches before this gesture is reachable.
        .contentShape(outerShape)
        .onTapGesture {
            if p > 0.5 { isSearchFocused = true }
        }
        .modifier(PeekGlassBackground(shape: outerShape))
        // Tap-to-expand overlay — only mounted at peek (`p < 0.5`).
        // Transparent Rectangle catches the entire pill area and routes
        // to `expandToHalf`. Once expanded the overlay disappears and
        // the parent ZStack's contentShape+onTapGesture (above) routes
        // taps to `isSearchFocused = true` for any region outside the
        // TextField's own text hit area.
        .overlay {
            if p < 0.5 {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(outerShape)
                    .onTapGesture {
                        panelModel.expandToHalf(animated: true)
                    }
            }
        }
        // Mango → amber field glow locked to the Search field's own
        // outerShape (the morphing capsule). Mounted as `.background`
        // so the outward bleed of the stroked-and-blurred halo
        // radiates past the field edge into the panel material; the
        // inward bleed is covered by the field's glass fill. NO clip
        // here — `.background` doesn't clip, so the blur extends
        // beyond the field bounds (clipped only by the floating-panel
        // surface boundary, as intended). Gated on `sf.bloomOn` for
        // isolated judgment.
        .background {
            if sfBloomOn {
                SolarFlareFieldGlow(
                    shape: outerShape,
                    accent: Color(hexString: "E8820A"),
                    secondary: Color(hexString: "F2A93B"),
                    isVisible: isSearchFocused
                )
            }
        }
        // Subtle Safari-style focus bounce — resting state sits at
        // 0.985, focus pops to 1.0 on a tight spring. Transform-only,
        // no layout / blur work, so it's effectively free. The halo
        // (.background above) and the field itself share the transform
        // so they bounce as one. Gated on reduceMotion.
        .scaleEffect(isSearchFocused ? 1.0 : 0.985)
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6),
            value: isSearchFocused
        )
        // .position uses the parent's coordinate space (the
        // GeometryReader, which is the surface). Centered horizontally;
        // centerY interpolated above.
        .position(x: geo.size.width / 2, y: centerY)
    }

    /// Linear interpolation. Clamps `t` to 0…1 defensively — the
    /// `peekProgress` source is already clamped, but morph values fed
    /// into geometry want to be robust if the input ever drifts.
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return a + (b - a) * clamped
    }

    /// Double variant of `lerp` — `.opacity()` takes a Double, and the
    /// CGFloat→Double cast was sprinkling `Double(lerp(...))` through
    /// the morphing field. One helper, one cast site.
    private func lerpD(_ a: Double, _ b: Double, _ t: CGFloat) -> Double {
        let clamped = min(max(Double(t), 0), 1)
        return a + (b - a) * clamped
    }

    /// Outer pill background. iOS 26+ Liquid Glass; falls back to
    /// `.regularMaterial` on earlier versions. Shape is parameterized
    /// so the morphing field can pass an interpolated rounded rect.
    ///
    /// TODO (iOS 26 glass-tier): the masked-flare inset region above
    /// should reveal REAL `.glassEffect` refraction through the same
    /// soft-edged PeekPillMask, so the upper tier gets live wet-glass
    /// while the floor (masked mesh) ships everywhere. Today the
    /// masked color sits over the flat dark plate — fine on iOS 18,
    /// but on iOS 26 the same mask alpha should drive a layered
    /// `glassEffect` reveal so the pill picks up canvas refraction
    /// behind the painted highlight, not just static color.
    private struct PeekGlassBackground<S: Shape>: ViewModifier {
        let shape: S
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
    }

    /// Mode icon + context ring composed as one unit so both surface
    /// states (collapsed pill, expanded header) share the same hit
    /// target and ring placement. Ring sits one pixel of breathing room
    /// outside the icon frame; tap inside the ring still triggers
    /// the parent action.
    ///
    /// `compact` shrinks the unit for inline placement at the leading
    /// edge of the Ask input row (44pt ring / 36pt icon) after the
    /// header-reclaim pass relocated the glyph there. Default (false)
    /// keeps the 57pt / 48pt scale used by other callers.
    @ViewBuilder
    private func modeIconWithRing(librarian: LibrarianState, compact: Bool = false) -> some View {
        let ringDiameter: CGFloat = compact ? 44 : 57
        let iconFrame: CGFloat = compact ? 36 : 48
        let iconSize: CGFloat = compact ? 18 : 24
        ZStack {
            ContextRing(fraction: librarian.contextFillFraction, diameter: ringDiameter)
            Image(systemName: librarian.activeMode.sfSymbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: iconFrame, height: iconFrame)
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    // MARK: - Expanded chrome (born-in)

    /// Expanded chrome: everything that fades in BEHIND the morphing
    /// field as `p` climbs past 0.5. The header, chips, transcript /
    /// search results, input row, and footer. The search field that
    /// used to live inline here has been retired — the morphing field
    /// in `body` now IS the search field at p=1. A transparent
    /// `Color.clear` of the same height holds the vertical pocket so
    /// the morphing field lands in the right slot when fully grown.
    ///
    /// `p` is threaded through so the heavy subtrees (transcript,
    /// search results, research panel) can perf-gate on `p > 0.4` —
    /// they don't render at peek when the chrome is invisible anyway,
    /// keeping the cost of a drag tick close to the cost of the field
    /// alone.
    @ViewBuilder
    private func expandedChrome(librarian: LibrarianState, p: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Header: grabber centered + chevron top-trailing. The mode
            // icon used to live top-leading here but was relocated to the
            // Ask input row's leading edge (header-reclaim pass) — the
            // freed vertical band tightens the chrome so the Search field
            // can land closer to the top with less dead space.
            ZStack(alignment: .top) {
                // FloatingPanel draws its own grabber on the surface;
                // we hide it in ContentView's panel mount so this
                // SwiftUI Capsule remains the single grabber owner —
                // sized/styled to match the Librarian's visual language.
                dragGrabber(librarian: librarian)
                    .padding(.top, 6)

                HStack(alignment: .top) {
                    Spacer()

                    Button {
                        panelModel.raiseToPeek(animated: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
            .padding(.bottom, 14)
            .contentShape(Rectangle())

            // Reserved slot for the morphing field at p=1. Height
            // matches the field's expandedH (52) + 10pt bottom gap.
            // Trimmed 68→62 to pull the chips + tile grid upward so
            // the bottom row (Capsule / Chats) clears the Ask field
            // at half detent. The field itself is drawn in the `body`
            // overlay; this just holds the pocket.
            Color.clear.frame(height: 62)

            scopeChipRow(librarian: librarian)
                .padding(.bottom, 4)

            // Perf gate. Below p=0.4 the chrome is fully invisible
            // (chromeOpacity = 0 until p=0.5) and the morphing field
            // covers the visible area anyway — skip building the
            // heavy transcript / search-results / research subtrees
            // so a drag tick stays cheap.
            if p > 0.4 {
                if !librarian.searchText.isEmpty {
                    // Search takes over the main pane while the field has
                    // content — instant MATCHES (C1) and RELATED (C2)
                    // render in place of the mode pipeline's transcript.
                    // Clearing the field restores the pipeline UI.
                    searchResultsView(librarian: librarian)
                        .frame(maxHeight: .infinity)
                } else if librarian.activeMode == .research {
                    researchPanel(librarian: librarian)
                } else {
                    // Conversation transcript (flexes), input row beneath
                    // it — chat-app convention so new messages land near
                    // the typing area.
                    transcriptView(librarian: librarian)
                        .frame(maxHeight: .infinity)

                    inputRow(librarian: librarian)
                        // Klein → cyan field glow locked to the Ask
                        // field's Capsule (matches `.clipShape(Capsule())`
                        // inside `inputRow`). Mounted as `.background`
                        // pre-padding so the stroked halo is
                        // concentric with the capsule, not with the
                        // padded slot. NO clip — outward bleed
                        // radiates into the panel material when Ask
                        // has focus. Ask overrides outer-pass width/
                        // blur/opacity via `sf.askGlow*` (shorter
                        // capsule in a busier area needs to radiate
                        // harder than Search). Gated on `sf.bloomOn`.
                        .background {
                            if sfBloomOn {
                                SolarFlareFieldGlow(
                                    shape: Capsule(),
                                    accent: Color(hexString: "1B59C2"),
                                    secondary: Color(hexString: "00BFFF"),
                                    isVisible: isInputFocused,
                                    widthOverride: askGlowWidth,
                                    blurOverride: askGlowBlur,
                                    opacityOverride: askGlowOpacity
                                )
                            }
                        }
                        // Subtle Safari-style focus bounce — applied
                        // OUTSIDE `.background` so the halo and the
                        // field scale together. Resting 0.985, focus
                        // 1.0 on a tight spring. Transform-only, no
                        // layout work. Gated on reduceMotion.
                        .scaleEffect(isInputFocused ? 1.0 : 0.985)
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6),
                            value: isInputFocused
                        )
                        .padding(.horizontal, 12)
                        // Top 6→14 adds breathing room above the Ask
                        // field so the tile grid's bottom row no
                        // longer collides with the glyph/capsule.
                        // Bottom 14→10 drops the Ask field a few pts
                        // closer to the panel bottom — frees more
                        // vertical room above for the tiles.
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                }
            } else {
                // Hold the vertical flex so the perf-gated swap doesn't
                // collapse the chrome's height while invisible — the
                // field-bottom reserved slot stays aligned with the
                // chips above it even before the gate flips.
                Spacer(minLength: 0)
            }

            endSessionFooter(librarian: librarian)
        }
        .frame(maxHeight: .infinity)
        // Lifted field-agnostic Done (Move 2 fix-pass v3 / Item 1).
        // Mounted as a bottom safeAreaInset so SwiftUI's automatic
        // keyboard avoidance — the same mechanism that already lifts
        // the chat input row above the keyboard — also lifts this
        // band. No manual `keyboardHeight` offset and no
        // `.ignoresSafeArea(.keyboard)`; both led to double-counting
        // and the mid-frame float seen in v2 / v3a. Visible only when
        // a field is up; reachable from both the search-results pane
        // and the transcript/input pane.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardHeight > 0 {
                VStack(spacing: 0) {
                    // Hairline rule so the band reads as a toolbar
                    // rather than a floating word above the keyboard.
                    Color.white.opacity(0.1)
                        .frame(height: 0.5)
                    HStack {
                        Spacer()
                        liftedDoneButton
                    }
                    .padding(.trailing, 16)
                    .padding(.vertical, 12)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: librarian.searchText) { oldValue, newValue in
            librarian.updateSearchMatches(store: store)
            librarian.kickOffSemanticSearch(store: store)
            // First non-empty character → promote to full so the
            // results pane has the most room. The focus-driven promote
            // in `.onChange(of: isInputFocused)` usually fires earlier
            // (on focus, before the first keystroke), but this stays
            // as a safety net for paste / programmatic write paths
            // that bypass focus.
            guard oldValue.isEmpty && !newValue.isEmpty else { return }
            panelModel.expandToFull(animated: true)
        }
        .confirmationDialog(
            "End session?",
            isPresented: $showEndDialog,
            titleVisibility: .visible
        ) {
            Button("Save to corpus") {
                Task { await saveSession(librarian: librarian) }
            }
            Button("Clear", role: .destructive) {
                librarian.clearSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save this session as a note, or clear it without saving.")
        }
    }

    /// Field-agnostic keyboard dismiss (Move 2 fix-pass B). Lifted out
    /// of `inputRow` so it's reachable from the search-results pane
    /// too — search has no input row to host its own dismiss. Resigns
    /// both focus states so a single tap clears whichever field is
    /// live without the surface having to know which one. Never moves
    /// the panel (probe Round 2: dismiss leaves the panel at full).
    private var liftedDoneButton: some View {
        Button {
            isInputFocused = false
            isSearchFocused = false
        } label: {
            Text("Done")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .contentShape(Rectangle())
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss keyboard")
    }

    /// Recompute `activeAccent` from the two @FocusState bindings.
    /// Search wins if both are somehow set (shouldn't happen — focus
    /// is exclusive — but Search is the higher-up field, so a tie
    /// favors it). Wrapped in `withAnimation` so the panel edge-glow's
    /// color crossfade rides the same easing as the field glows'
    /// per-field opacity ramps; ReduceMotion gates the easing.
    private func updateActiveAccent() {
        let next: Color?
        if isSearchFocused {
            next = Color(hexString: "E8820A")
        } else if isInputFocused {
            next = Color(hexString: "1B59C2")
        } else {
            next = nil
        }
        if reduceMotion {
            activeAccent = next
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                activeAccent = next
            }
        }
    }

    /// Footer row holding the End button. Visible whenever the session
    /// has *anything* — either live turns or a compacted summary —
    /// since post-compaction the live history is empty but the session
    /// itself is very much in progress. Counter shows total turns
    /// (compacted + live) so the user's sense of "how much have I done
    /// this session" survives a compaction pass. Save is async
    /// (`addNode` writes JSON + recomputes layout) so the button shows
    /// a progress state while in flight.
    @ViewBuilder
    private func endSessionFooter(librarian: LibrarianState) -> some View {
        let liveCount = librarian.sessionHistory.count
        let totalCount = liveCount + librarian.compactedExchangeCount
        let hasSession = liveCount > 0 || librarian.compactedSummary != nil
        if hasSession {
            HStack {
                Spacer()
                Button {
                    showEndDialog = true
                } label: {
                    HStack(spacing: 6) {
                        if isSavingSession {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white.opacity(0.7))
                        } else {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(isSavingSession ? "Saving…" : "End session (\(totalCount))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSavingSession)
                Spacer()
            }
            .padding(.bottom, 10)
        }
    }

    private func saveSession(librarian: LibrarianState) async {
        isSavingSession = true
        _ = await librarian.saveSessionAsNode(store: store)
        librarian.clearSession()
        isSavingSession = false
    }

    private func sendIsEnabled(librarian: LibrarianState) -> Bool {
        !librarian.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !librarian.isLoading
    }

    // MARK: - Instant search (ws-instant-search C1)

    /// Persistent search field at the top of the Librarian. Independent
    /// of the mode pipeline's `inputText`; typing here drives the
    /// MATCHES + RELATED sections that take over the transcript pane
    /// while non-empty. Available regardless of `activeMode`.
    @ViewBuilder
    private func searchField(librarian: LibrarianState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            TextField("Search", text: Binding(
                get: { librarian.searchText },
                set: { librarian.searchText = $0 }
            ))
                .focused($isSearchFocused)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .tint(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !librarian.searchText.isEmpty {
                Button {
                    librarian.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
    }

    /// MATCHES (text) and RELATED (semantic) sections rendered when
    /// the search field is non-empty. Resolves node IDs against the
    /// live store at render time so renames/deletes between
    /// keystroke and frame don't surface stale rows.
    @ViewBuilder
    private func searchResultsView(librarian: LibrarianState) -> some View {
        let matchNodes: [Node] = librarian.searchMatches.compactMap { id in
            store.nodes.first(where: { $0.id == id })
        }
        let related = librarian.searchRelated
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if matchNodes.isEmpty && related.isEmpty && !librarian.searchSemanticInFlight {
                    Text("No matches")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 12)
                }

                if !matchNodes.isEmpty {
                    Text("MATCHES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 4)
                    ForEach(matchNodes, id: \.id) { node in
                        Button {
                            openNode(node.id)
                        } label: {
                            SearchMatchRow(node: node)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    Text("RELATED")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.45))
                    if librarian.searchSemanticInFlight {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white.opacity(0.45))
                    }
                }
                .padding(.top, !matchNodes.isEmpty ? 8 : 4)

                ForEach(related) { rel in
                    if let node = store.nodes.first(where: { $0.id == rel.nodeID }) {
                        Button {
                            openNode(rel.nodeID)
                        } label: {
                            SearchRelatedRow(node: node, snippet: rel.snippet)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .floatingPanelScrollTracking(proxy: proxy)
    }

    /// Hand a search-result tap to the host NavigationStack via the
    /// router. Mirrors the `CitationSheet.onOpenNote` pattern so the
    /// detail-view push is owned by `CanvasView` / `NodeListView`,
    /// not the Librarian surface. v1 navigates to top of the detail;
    /// scroll-to-block + highlight is its own follow-on brief.
    ///
    /// Also drops the panel to `.half` so the pushed detail view is
    /// visible above the Librarian rather than covered by it at full.
    /// The drop + push happen in the same tick; the host's
    /// `pendingNodeNavigationID` dedupe guards against double-pushes
    /// if the user multi-taps the same row.
    private func openNode(_ nodeID: String) {
        isInputFocused = false
        // Blunt resign-first-responder kept defensively: the search
        // TextField lives across the UIHostingController/FloatingPanel
        // boundary, so unfocusing via @FocusState alone has missed in
        // the past. Sending up the responder chain ensures whoever
        // holds the keyboard releases it.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        panelModel.dropToHalf(animated: true)
        router.pendingNodeNavigationID = nodeID
    }

    // MARK: - Chat layout (c14)

    /// Input row at the bottom of the chat pane. Lifted out of
    /// `expandedBody` so the transcript can sit above it as the
    /// flexing element — chat-app convention: history scrolls above,
    /// typing happens at the bottom near the keyboard.
    @ViewBuilder
    private func inputRow(librarian: LibrarianState) -> some View {
        // Klein Blue identity (#1B59C2). Caret + trailing-slot glyph
        // (mic or send) read against this hue so the Ask field is
        // clearly differentiated from the Mango Search field above.
        // Body text stays white; only the accents are Klein.
        let klein = Color(hexString: "1B59C2")
        // Within-family top→bottom gradient: cyan lifted top, klein
        // grounded bottom. Mirrors the morphing field's mango→amber
        // gradient direction so the two fields read as a consistent
        // treatment, just different families.
        let kleinGrad = LinearGradient(
            colors: [Color(hexString: "00BFFF"), Color(hexString: "1B59C2")],
            startPoint: .top,
            endPoint: .bottom
        )
        let hasText = !librarian.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        HStack(spacing: 8) {
            // Mode identity glyph (relocated from header in the
            // header-reclaim pass). Tap opens the mode dropdown
            // popover, which now anchors to this inline placement.
            // `compact` renders the ring at 44pt / icon at 36pt so it
            // sits comfortably inside the Ask field's 48pt min-height
            // band without dwarfing the TextField.
            Button {
                showModeDropdown = true
            } label: {
                modeIconWithRing(librarian: librarian, compact: true)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModeDropdown, arrowEdge: .top) {
                modeDropdown(librarian: librarian)
                    .presentationCompactAdaptation(.popover)
            }
            // 2pt leading nests the 44pt ring concentrically inside
            // the capsule's left rounded end — the prior 6pt floated
            // the glyph inboard of the curve.
            .padding(.leading, 2)

            TextField("Ask", text: Binding(
                get: { librarian.inputText },
                set: { librarian.inputText = $0 }
            ), axis: .vertical)
                .focused($isInputFocused)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white)
                .tint(klein)
                // Leading 14 (on top of the HStack's 8pt spacing) gives
                // the "Ask" placeholder/text ~22pt of clearance from the
                // glyph's ring — the prior `.horizontal, 8` had the text
                // hugging the glyph. Trailing stays tight at 8 so the
                // mic/send slot keeps its Messages-pattern compactness.
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 12)
                .lineLimit(1...4)

            // Messages-pattern trailing slot. Empty field → dictation
            // mic (Klein, visual-only this pass — speech wiring lives
            // in a later brief). Non-empty → clear (×) + send arrow
            // that runs the Ask pipeline. The send swaps to Klein when
            // enabled, dim white when disabled (matches the prior
            // disabled state). The lifted field-agnostic Done (Move 2
            // fix-pass v3 Item 1) still handles keyboard dismiss for
            // both panes.
            let isHot = dictation.isListening && dictation.activeToken == "ask"
            HStack(spacing: 8) {
                // × clear — whenever there's text (dictating or not).
                if hasText {
                    Button {
                        librarian.inputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear input")
                }
                // Dictating WITH text, or idle WITH text → SEND. Sending
                // also ends any active dictation (one move, no separate
                // stop step — Ask's intent is to send, not to review).
                if hasText {
                    Button {
                        if dictation.isListening && dictation.activeToken == "ask" {
                            dictation.stop()
                        }
                        Task { await librarian.executeQuery(store: store) }
                    } label: {
                        let enabled = sendIsEnabled(librarian: librarian)
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                enabled
                                    ? AnyShapeStyle(kleinGrad)
                                    : AnyShapeStyle(Color.white.opacity(0.2))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!sendIsEnabled(librarian: librarian))
                } else if isHot {
                    // Dictating but NOTHING said yet → stop (nothing to
                    // send, so offer a way out rather than a dead send).
                    Button {
                        dictation.toggle(token: "ask", baseline: librarian.inputText,
                                         onUpdate: { librarian.inputText = $0 })
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(kleinGrad)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop dictation")
                } else {
                    // Idle, empty → mic.
                    Button {
                        dictation.toggle(token: "ask", baseline: librarian.inputText,
                                         onUpdate: { librarian.inputText = $0 })
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(kleinGrad)
                            .opacity(0.8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dictate")
                }
            }
            .padding(.trailing, 10)
        }
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.04))
        // Whole-capsule tap target — single-tap focuses Ask from
        // anywhere on the pill (icons, the padded gap to the right of
        // the mode glyph, the trailing area before mic/send), not
        // just the TextField text region. The leading mode-glyph
        // Button and trailing send/mic Button consume their own taps
        // (`.buttonStyle(.plain)` does not propagate), so they still
        // fire correctly; this gesture only catches the "empty"
        // capsule regions.
        .contentShape(Capsule())
        .onTapGesture {
            isInputFocused = true
        }
        // Capsule (auto-rounds ends to half-height) so the terminating
        // ends are true semicircles concentric with the 44pt glyph ring
        // on the leading edge — the prior fixed cornerRadius: 22 read
        // as rounded-rect, not capsule, especially when the TextField
        // grew past one line (lineLimit 1...4) and corners stayed at
        // 22 while the field got taller. Capsule keeps the curve =
        // half-height at every line count.
        //
        // Resting stroke is a soft white top→bottom gradient (NOT the
        // prior solid Klein outline) — restores the lit-top-edge look
        // the Search field gets for free from its PeekGlassBackground
        // glass rim, so the two fields read as the same material
        // family without Ask reading as the "selected" one at rest.
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }

    /// Stable id for the bottom anchor used by the scroll-to-latest
    /// behavior. Sentinel string, not a real exchange id.
    private static let transcriptBottomAnchor = "_transcript_bottom"

    /// The conversation pane. Renders compacted summary (if any) +
    /// each exchange in `sessionHistory` + any in-flight or error
    /// tail. When the session is empty *and* nothing is pending,
    /// falls through to the existing ghost-whisper suggestions so
    /// the surface still feels alive on first open.
    @ViewBuilder
    private func transcriptView(librarian: LibrarianState) -> some View {
        let isResponseError: Bool = {
            guard let response = librarian.response else { return false }
            if case .error = response { return true }
            return false
        }()
        let hasAny = !librarian.sessionHistory.isEmpty
            || librarian.compactedSummary != nil
            || librarian.pendingQuery != nil
            || librarian.isLoading
            || isResponseError

        if hasAny {
            // Rename to `scrollProxy` so the outer `proxy:
            // FloatingPanelProxy` (used by `.floatingPanelScrollTracking`
            // below) isn't shadowed by SwiftUI's `ScrollViewProxy`.
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let summary = librarian.compactedSummary, !summary.isEmpty {
                            transcriptCompactedPreamble(summary: summary, turns: librarian.compactedExchangeCount)
                        }

                        ForEach(Array(librarian.sessionHistory.enumerated()), id: \.element.id) { idx, exchange in
                            let isLatest = (idx == librarian.sessionHistory.count - 1)
                            let liveCitations: [BlockMatch]? = {
                                guard isLatest else { return nil }
                                if case let .ask(_, citations, _)? = librarian.response {
                                    return citations
                                }
                                return nil
                            }()
                            transcriptExchange(
                                librarian: librarian,
                                exchange: exchange,
                                liveCitations: liveCitations
                            )
                        }

                        transcriptInflightTail(librarian: librarian)

                        Color.clear
                            .frame(height: 1)
                            .id(Self.transcriptBottomAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: librarian.sessionHistory.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(Self.transcriptBottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: librarian.isLoading) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(Self.transcriptBottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: librarian.streamingText) { _, _ in
                    // Stream-follow: each delta lands new content at the
                    // tail, so the scroll view chases it the way a chat
                    // app rides typing. No animation — token cadence is
                    // already smooth, and animating per-delta stutters.
                    scrollProxy.scrollTo(Self.transcriptBottomAnchor, anchor: .bottom)
                }
                .onAppear {
                    scrollProxy.scrollTo(Self.transcriptBottomAnchor, anchor: .bottom)
                }
                .floatingPanelScrollTracking(proxy: proxy)
            }
        } else {
            ScrollView {
                capabilityTileGrid(librarian: librarian)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .floatingPanelScrollTracking(proxy: proxy)
        }
    }

    /// Preamble pill for a session that has at least one compaction
    /// pass behind it. Sits above the live history so the user sees
    /// the conversation's full arc, not just the post-compaction tail.
    @ViewBuilder
    private func transcriptCompactedPreamble(summary: String, turns: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Earlier in session — \(turns) turn\(turns == 1 ? "" : "s") compacted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.4)
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// One historical exchange. Renders as: right-aligned query
    /// bubble, then the response body (markdown / retrieval / plain
    /// text per the exchange's mode), then citation chips when
    /// applicable. `liveCitations` is non-nil only for the most
    /// recent exchange when it still matches `librarian.response`'s
    /// .ask citations — that lets the latest chips open the
    /// `CitationSheet` for block-level pull quotes, while older
    /// chips navigate direct (no live BlockMatch data to drive the
    /// sheet).
    @ViewBuilder
    private func transcriptExchange(
        librarian: LibrarianState,
        exchange: LibrarianState.LibrarianExchange,
        liveCitations: [BlockMatch]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            transcriptQueryBubble(text: exchange.query)
            transcriptResponseBody(librarian: librarian, exchange: exchange, liveCitations: liveCitations)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func transcriptQueryBubble(text: String) -> some View {
        HStack {
            Spacer(minLength: 32)
            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(hexString: "00BFFF").opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func transcriptResponseBody(
        librarian: LibrarianState,
        exchange: LibrarianState.LibrarianExchange,
        liveCitations: [BlockMatch]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !exchange.responseText.isEmpty {
                Text(attributedMarkdown(exchange.responseText))
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if !exchange.citationNodeIDs.isEmpty {
                // Retrieval-only turn (Navigate mode) — render the
                // matched nodes inline so the transcript shows the
                // actual answer (a list of notes), not an empty bubble.
                retrievalList(nodeIDs: exchange.citationNodeIDs)
            }

            if !exchange.citationNodeIDs.isEmpty && !exchange.responseText.isEmpty {
                transcriptCitationRow(
                    nodeIDs: exchange.citationNodeIDs,
                    liveCitations: liveCitations
                )
            }

            if !exchange.responseText.isEmpty {
                let isActive = speech.activeToken == exchange.id
                let showPause = isActive && speech.isSpeaking && !speech.isPaused
                let voiceSelection = Binding<String?>(
                    get: { speech.selectedVoiceIdentifier },
                    set: { speech.selectedVoiceIdentifier = $0 }
                )
                HStack(spacing: 14) {
                    Button {
                        speech.toggle(token: exchange.id, text: exchange.responseText)
                    } label: {
                        Image(systemName: showPause ? "pause" : "play")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPause ? "Pause" : "Play")

                    Menu {
                        Picker("Voice", selection: voiceSelection) {
                            Text("Best available").tag(String?.none)
                            ForEach(SpeechSynthesisService.availableVoices, id: \.identifier) { v in
                                Text(voiceLabel(v)).tag(Optional(v.identifier))
                            }
                        }
                    } label: {
                        Image(systemName: "person.wave.2")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose voice")
                }
                .padding(.top, 2)
            }
        }
    }

    /// Citation chip row beneath an Ask response. Latest exchange
    /// gets the live-citation sheet (block-level pull quotes); older
    /// exchanges nav-direct to the source note since we no longer
    /// hold the BlockMatch data needed to power the sheet.
    @ViewBuilder
    private func transcriptCitationRow(
        nodeIDs: [String],
        liveCitations: [BlockMatch]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(nodeIDs, id: \.self) { nodeID in
                    if let liveCitations {
                        citationChip(nodeID: nodeID, allCitations: liveCitations)
                    } else {
                        transcriptHistoricalChip(nodeID: nodeID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptHistoricalChip(nodeID: String) -> some View {
        let node = store.nodes.first { $0.id == nodeID }
        let title = node?.title ?? "Untitled"

        Button {
            router.pendingNodeNavigationID = nodeID
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(citationDotColor(node: node))
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// In-flight tail: the user's just-sent query as a bubble + either
    /// the silent shimmer (pre-token) or the streamed token tail with a
    /// blinking cursor (mid-stream), OR an error pill when the latest
    /// pipeline failed (errors aren't appended to history, so they only
    /// show here). Returns an empty view when nothing is in flight.
    @ViewBuilder
    private func transcriptInflightTail(librarian: LibrarianState) -> some View {
        if let pending = librarian.pendingQuery, librarian.isLoading {
            VStack(alignment: .leading, spacing: 10) {
                transcriptQueryBubble(text: pending)
                inflightAnswerTail(librarian: librarian)
            }
        } else if librarian.isLoading {
            inflightAnswerTail(librarian: librarian)
        } else if case let .error(message)? = librarian.response {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color(hexString: "E8820A"))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hexString: "E8820A").opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Two-phase in-flight answer body. Once tokens are flowing, renders
    /// the raw streamed text with a trailing blinking cursor — same font
    /// and color as the final response so the transition into the
    /// committed exchange is invisible. Before tokens arrive (or for the
    /// Foundation Model path, which yields one chunk at the end), shows
    /// the pulsing shimmer.
    @ViewBuilder
    private func inflightAnswerTail(librarian: LibrarianState) -> some View {
        if librarian.isStreaming && !librarian.streamingText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(librarian.streamingText)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                StreamingCursorView()
            }
        } else {
            ThinkingShimmerView()
        }
    }

    /// Single source chip — node color dot + node title. Tap opens
    /// `CitationSheet` so the user can read the actual passages that
    /// fed the prompt before deciding to jump into the note. The
    /// "Open" button in the sheet hands navigation off to the host
    /// NavigationStack (same pattern as retrieval rows).
    @ViewBuilder
    private func citationChip(nodeID: String, allCitations: [BlockMatch]) -> some View {
        let node = store.nodes.first { $0.id == nodeID }
        let title = node?.title ?? "Untitled"

        Button {
            presentedCitation = PresentedCitation(nodeID: nodeID, citations: allCitations)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(citationDotColor(node: node))
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium:  q = "Premium"
        case .enhanced: q = "Enhanced"
        default:        q = "Default"
        }
        return "\(v.name) — \(q)"
    }

    private func citationDotColor(node: Node?) -> Color {
        guard let primary = node?.primaryTag,
              let storeTag = store.tags.first(where: { $0.name == primary }),
              let color = Color(hex: storeTag.colorHex)
        else { return .gray.opacity(0.6) }
        return color
    }

    /// `AttributedString` markdown with a forgiving fallback — if the
    /// model emits something the parser chokes on, we still show the
    /// raw text rather than dropping the answer entirely.
    private func attributedMarkdown(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(text)
    }

    @ViewBuilder
    private func retrievalList(nodeIDs: [String]) -> some View {
        let nodes = nodeIDs.compactMap { id in
            store.nodes.first { $0.id == id }
        }

        if nodes.isEmpty {
            Text("No matches.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.55))
        } else {
            LazyVStack(spacing: 10) {
                ForEach(nodes) { node in
                    Button {
                        router.pendingNodeNavigationID = node.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !node.summary.isEmpty {
                                Text(node.summary)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(2)
                            }

                            Text(node.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func modeDropdown(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LibrarianState.Mode.allCases, id: \.self) { mode in
                Button {
                    librarian.activeMode = mode
                    showModeDropdown = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.sfSymbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 22)

                        Text(mode.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)

                        Spacer(minLength: 16)

                        if mode == librarian.activeMode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Disabled affordance for a future "Research" mode — kept in
            // the dropdown so the concept stays visible to the user but
            // not yet selectable. No backing enum case: when it ships,
            // promote to a real Mode.
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 22)

                Text("Research")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))

                Spacer(minLength: 16)

                Text("Coming soon")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .accessibilityLabel("Research mode, coming soon")
        }
        .frame(minWidth: 180)
        .background(Color(red: 0.04, green: 0.04, blue: 0.06))
    }

    // MARK: - Capability tile grid (landing launchpad)

    /// 2×2 grid that occupies the landing pocket (no session, empty
    /// search) in place of the retired "Try Asking" suggestions list.
    /// Frames the Librarian as a launchpad into Insights / Inbox /
    /// Capsule / Chats instead of a dead suggestion list.
    ///
    /// Tap destinations are stubbed this pass — the workstreams that
    /// own each surface (corpus reflection, Inbox SB134, chat
    /// primitive, capsule export) wire them up as they land. Capsule
    /// renders dimmed + inert until its export format is locked.
    @ViewBuilder
    private func capabilityTileGrid(librarian: LibrarianState) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        LazyVGrid(columns: columns, spacing: 12) {
            capabilityTile(
                label: "Insights",
                systemImage: "sparkles",
                isEnabled: true
            ) {
                // TODO: route to corpus-reflection workstream
            }
            capabilityTile(
                label: "Inbox",
                systemImage: "tray",
                isEnabled: true
            ) {
                // TODO: route to dashboard Inbox surface (SB134).
                // Future badge count slot lives on this tile.
            }
            capabilityTile(
                label: "Capsule",
                systemImage: "shippingbox",
                isEnabled: false
            ) {
                // Dimmed + inert until export format is locked.
            }
            capabilityTile(
                label: "Chats",
                systemImage: "bubble.left.and.bubble.right",
                isEnabled: true
            ) {
                // TODO: route to chat primitive history
            }
        }
    }

    /// One tile in `capabilityTileGrid`. Icon-led card with a small
    /// label beneath. Solar Flare rim-light treatment lands in a
    /// later art-direction pass — this is the placeholder card style.
    ///
    /// `isEnabled == false` renders the tile dimmed and skips the
    /// Button wrapper entirely so the tile reads as a "coming soon"
    /// placeholder rather than a tappable affordance (Capsule tile).
    @ViewBuilder
    private func capabilityTile(
        label: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let card = VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))

        if isEnabled {
            Button(action: action) { card }
                .buttonStyle(.plain)
        } else {
            card.opacity(0.4)
        }
    }

    // MARK: - Research mode (c8)

    /// Replaces the Ask input + response area when `activeMode == .research`.
    /// Renders the four-stage stepper above and the per-stage content below.
    /// Stage 1 lights up in c8.2; Stages 2–4 are stub placeholders pointing
    /// at upcoming commits.
    @ViewBuilder
    private func researchPanel(librarian: LibrarianState) -> some View {
        VStack(spacing: 12) {
            researchStepper(librarian: librarian)
                .padding(.horizontal, 16)

            researchStageContent(librarian: librarian)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 2)
    }

    /// Four-dot stepper. Numbered chip + stage name + connector line.
    /// Tap a stage to jump there (no validation gates for c8 — Stage 1 is
    /// the only one with real content; later commits add per-stage
    /// `canAdvance` rules).
    @ViewBuilder
    private func researchStepper(librarian: LibrarianState) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(LibrarianState.ResearchStage.allCases.enumerated()), id: \.element) { idx, stage in
                researchStepperDot(stage: stage, librarian: librarian)
                if idx < LibrarianState.ResearchStage.allCases.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func researchStepperDot(stage: LibrarianState.ResearchStage, librarian: LibrarianState) -> some View {
        let isActive = librarian.researchStage == stage
        let isPast = stage.rawValue < librarian.researchStage.rawValue
        Button {
            librarian.researchStage = stage
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(isActive || isPast ? Color.white.opacity(0.85) : Color.white.opacity(0.08))
                        .frame(width: 22, height: 22)
                    Text("\(stage.rawValue + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive || isPast ? .black : .white.opacity(0.5))
                }
                Text(stage.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? .white : .white.opacity(0.4))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func researchStageContent(librarian: LibrarianState) -> some View {
        switch librarian.researchStage {
        case .select:
            researchSelectStage(librarian: librarian)
        case .frame:
            researchFrameStage(librarian: librarian)
        case .export:
            researchExportStage(librarian: librarian)
        case .importReview:
            researchImportStage(librarian: librarian)
        }
    }

    // MARK: - Stage 4 (Import)

    /// Stage 4 — Import. User pastes the model's reply (either the
    /// raw transcript or the structured JSON Stage 2's toggle asked
    /// for). AirPad parses on text-change into review candidates;
    /// the user accepts or dismisses each one individually. Nothing
    /// enters the corpus until the user taps Accept.
    @ViewBuilder
    private func researchImportStage(librarian: LibrarianState) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    researchImportPasteArea(librarian: librarian)
                    researchImportStatusRow(librarian: librarian)
                    if let error = librarian.researchImportError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hexString: "E8820A"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hexString: "E8820A").opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    researchImportCandidateList(librarian: librarian)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .floatingPanelScrollTracking(proxy: proxy)

            researchImportFooter(librarian: librarian)
        }
    }

    @ViewBuilder
    private func researchImportPasteArea(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste the model's reply")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(0.4)
            ZStack(alignment: .topLeading) {
                if librarian.researchImportText.isEmpty {
                    Text("Paste here — JSON from a structured return, or the full transcript with `## headings` per candidate note.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { librarian.researchImportText },
                    set: { newValue in
                        librarian.researchImportText = newValue
                        librarian.parseImportPaste()
                    }
                ))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 110, maxHeight: 180)
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func researchImportStatusRow(librarian: LibrarianState) -> some View {
        HStack(spacing: 8) {
            researchImportModeBadge(mode: librarian.researchImportParseMode)
            Spacer()
            if librarian.researchImportAcceptedCount > 0 {
                Text("\(librarian.researchImportAcceptedCount) added to corpus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hexString: "00BFFF"))
            }
        }
    }

    @ViewBuilder
    private func researchImportModeBadge(mode: LibrarianState.ImportParseMode) -> some View {
        let (label, color): (String?, Color) = {
            switch mode {
            case .none:
                return (nil, .clear)
            case .structuredJSON:
                return ("Detected: structured JSON", Color(hexString: "00BFFF"))
            case .transcriptHeadingSplit:
                return ("Detected: transcript with headings", .white.opacity(0.6))
            case .transcriptSingle:
                return ("Detected: single block (no headings found)", .white.opacity(0.6))
            }
        }()
        if let label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func researchImportCandidateList(librarian: LibrarianState) -> some View {
        if librarian.researchImportCandidates.isEmpty {
            if librarian.researchImportText.isEmpty {
                Text("Paste a model reply above to extract candidate notes. AirPad understands JSON from the structured-return toggle, or markdown with `## headings`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            } else if librarian.researchImportAcceptedCount > 0 {
                Text("All candidates reviewed. Paste another reply to extract more, or head back.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(librarian.researchImportCandidates) { candidate in
                    researchImportCandidateCard(librarian: librarian, candidate: candidate)
                }
            }
        }
    }

    /// One candidate card. Title up top, body preview below (3-line
    /// clamp so a long imported note doesn't dominate the review
    /// surface), Accept + Dismiss in a row. Accept is the cyan-tinted
    /// affirmative; Dismiss is muted so the eye doesn't read it as
    /// the primary action.
    @ViewBuilder
    private func researchImportCandidateCard(
        librarian: LibrarianState,
        candidate: LibrarianState.ImportCandidate
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if !candidate.content.isEmpty {
                Text(candidate.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in
                        await librarian.acceptImportCandidate(id: candidate.id, store: store)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Accept")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(hexString: "00BFFF").opacity(0.22))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    librarian.dismissImportCandidate(id: candidate.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Stage 4 footer. Back goes to Export. There's no Next — Import
    /// is the terminal stage. Once the user has accepted what they
    /// wanted, they close the session via the surface-level End
    /// affordance (no per-stage Done needed).
    @ViewBuilder
    private func researchImportFooter(librarian: LibrarianState) -> some View {
        HStack(spacing: 12) {
            Button {
                librarian.researchStage = .export
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            let remaining = librarian.researchImportCandidates.count
            if remaining > 0 {
                Text("\(remaining) to review")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    // MARK: - Stage 3 (Export)

    /// Stage 3 — Export. Assembles the briefing text from the user's
    /// frame plus the selected nodes' titles and bodies, optionally
    /// appending a JSON-schema instruction when the Stage 2 toggle is
    /// on. Shows node / word / token-estimate metrics, a read-only
    /// preview, and Copy + Share actions. The user pastes the result
    /// into Claude, ChatGPT, or any other long-context model.
    @ViewBuilder
    private func researchExportStage(librarian: LibrarianState) -> some View {
        let briefing = researchBriefingText(librarian: librarian)
        let metrics = researchExportMetrics(text: briefing, librarian: librarian)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    researchExportMetricsRow(metrics: metrics)

                    researchExportPreview(text: briefing)

                    researchExportActions(librarian: librarian, briefing: briefing)

                    Text("Works with Claude, ChatGPT, and other long-context models. Paste this briefing into a fresh conversation.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .floatingPanelScrollTracking(proxy: proxy)

            researchExportFooter(librarian: librarian)
        }
    }

    private struct ResearchExportMetrics {
        let nodeCount: Int
        let wordCount: Int
        let tokenEstimate: Int
    }

    /// ~4 chars/token is the established English-text heuristic for both
    /// Anthropic and OpenAI tokenizers — close enough to size a briefing
    /// against a 200k-context Claude or 128k-context GPT without
    /// shipping a real tokenizer to the device.
    private static let researchTokenCharsPerToken: Double = 4.0

    private func researchExportMetrics(text: String, librarian: LibrarianState) -> ResearchExportMetrics {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        let tokens = Int((Double(text.count) / Self.researchTokenCharsPerToken).rounded())
        return ResearchExportMetrics(
            nodeCount: librarian.researchSelectedNodeIDs.count,
            wordCount: words,
            tokenEstimate: tokens
        )
    }

    @ViewBuilder
    private func researchExportMetricsRow(metrics: ResearchExportMetrics) -> some View {
        HStack(spacing: 16) {
            researchMetricChip(value: "\(metrics.nodeCount)", label: "nodes")
            researchMetricChip(value: researchAbbreviated(metrics.wordCount), label: "words")
            researchMetricChip(value: "~" + researchAbbreviated(metrics.tokenEstimate), label: "tokens")
            Spacer()
        }
    }

    @ViewBuilder
    private func researchMetricChip(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.4)
        }
    }

    /// Compact form for word/token counts so a 12,400-word briefing
    /// renders "12.4k" instead of blowing out the chip row.
    private func researchAbbreviated(_ value: Int) -> String {
        if value >= 1000 {
            let k = Double(value) / 1000.0
            return String(format: "%.1fk", k)
        }
        return "\(value)"
    }

    @ViewBuilder
    private func researchExportPreview(text: String) -> some View {
        Text(text.isEmpty ? "Nothing to export yet — pick at least one node in Stage 1." : text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(text.isEmpty ? 0.4 : 0.8))
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func researchExportActions(librarian: LibrarianState, briefing: String) -> some View {
        HStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = briefing
                researchExportCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    researchExportCopied = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: researchExportCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text(researchExportCopied ? "Copied" : "Copy")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(briefing.isEmpty)

            ShareLink(item: briefing) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Share")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(briefing.isEmpty)
        }
    }

    @ViewBuilder
    private func researchExportFooter(librarian: LibrarianState) -> some View {
        HStack(spacing: 12) {
            Button {
                librarian.researchStage = .frame
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                librarian.researchStage = .importReview
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    /// Build the full briefing text. Frame goes first (the user's
    /// instruction to the model), followed by the selected nodes as
    /// titled sections so the model can ground its reasoning in
    /// specific passages, optionally followed by a JSON-schema
    /// instruction when the Stage 2 toggle is on.
    ///
    /// Body fallbacks: `summary` first (AI-derived gist), else
    /// concatenated text-bearing items. Empty selection returns just
    /// the frame so the preview still reads sensibly while the user
    /// is iterating on Stage 2 wording.
    private func researchBriefingText(librarian: LibrarianState) -> String {
        let frame = librarian.researchFrameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIDs = librarian.researchSelectedNodeIDs
        let selectedNodes = store.nodes
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }

        var sections: [String] = []
        if !frame.isEmpty {
            sections.append(frame)
        }

        if !selectedNodes.isEmpty {
            sections.append("Here are \(selectedNodes.count) note\(selectedNodes.count == 1 ? "" : "s") from my corpus:")
            for node in selectedNodes {
                sections.append(researchBriefingSection(for: node))
            }
        }

        if librarian.researchRequestStructuredReturn {
            sections.append(Self.researchStructuredReturnInstruction)
        }

        return sections.joined(separator: "\n\n")
    }

    private func researchBriefingSection(for node: Node) -> String {
        let title = node.title.isEmpty ? "Untitled" : node.title
        var lines: [String] = ["## \(title)"]
        if !node.summary.isEmpty {
            lines.append(node.summary)
        } else {
            let bodies = node.items.compactMap { $0.content }.filter { !$0.isEmpty }
            if !bodies.isEmpty {
                lines.append(bodies.joined(separator: "\n\n"))
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Schema instruction appended when the user has flipped the
    /// Stage 2 structured-return toggle. Targeted at Stage 4's import
    /// parser — a flat JSON array of `{title, content}` objects keeps
    /// the model honest and the parser simple. Tags / metadata can
    /// land in a follow-up if the import flow grows richer.
    private static let researchStructuredReturnInstruction = """
    Return your response as JSON in this exact shape so AirPad can import the result:

    ```json
    [
      { "title": "Note title", "content": "Full note body in markdown" },
      …
    ]
    ```

    Include one object per distinct insight, pattern, or new note worth capturing. Use plain markdown inside `content`. Do not wrap the JSON in any extra commentary.
    """

    // MARK: - Stage 2 (Frame)

    /// Stage 2 — Frame. Multi-line text editor pre-populated with a
    /// suggestion derived from the user's Stage 1 selection. Carries a
    /// schema-aware-return toggle whose effect is realized when Stage 3
    /// (Export) assembles the briefing prompt; storing it here keeps
    /// the user's preference across stage navigation.
    @ViewBuilder
    private func researchFrameStage(librarian: LibrarianState) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What do you want from this conversation?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 4)

                    researchFrameEditor(librarian: librarian)

                    researchStructuredToggle(librarian: librarian)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .floatingPanelScrollTracking(proxy: proxy)

            researchFrameFooter(librarian: librarian)
        }
        .onAppear { researchSeedFrameIfNeeded(librarian: librarian) }
    }

    @ViewBuilder
    private func researchFrameEditor(librarian: LibrarianState) -> some View {
        TextField(
            "Tell the model what you want from this session…",
            text: Binding(
                get: { librarian.researchFrameText },
                set: { librarian.researchFrameText = $0 }
            ),
            axis: .vertical
        )
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .tint(.white)
        .lineLimit(4...10)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func researchStructuredToggle(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { librarian.researchRequestStructuredReturn },
                set: { librarian.researchRequestStructuredReturn = $0 }
            )) {
                Text("Request schema-aware structured return")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .tint(Color(hexString: "00BFFF"))

            Text("Asks the model to reply in a JSON shape AirPad can import directly in Stage 4.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder
    private func researchFrameFooter(librarian: LibrarianState) -> some View {
        let count = librarian.researchSelectedNodeIDs.count
        HStack(spacing: 12) {
            Button {
                librarian.researchStage = .select
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(count) node\(count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))

            Button {
                librarian.researchStage = .export
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    /// Populate `researchFrameText` with a default suggestion on first
    /// entry to Stage 2. Re-entering the same session leaves the user's
    /// text alone (including deliberate clear-to-empty). The suggestion
    /// is intentionally simple — the brief's "AirPad suggests a frame"
    /// is satisfied by a sensible question seed that the user can keep,
    /// edit, or wipe; richer substrate-aware framing is a follow-up.
    private func researchSeedFrameIfNeeded(librarian: LibrarianState) {
        guard !librarian.researchFrameSeeded else { return }
        librarian.researchFrameSeeded = true
        guard librarian.researchFrameText.isEmpty else { return }
        let count = librarian.researchSelectedNodeIDs.count
        if count == 0 {
            librarian.researchFrameText = "What patterns or open questions emerge across this slice of the corpus?"
        } else {
            librarian.researchFrameText = "What patterns, tensions, or open questions emerge across these \(count) notes?"
        }
    }

    /// Stage 1 — Select. Scrollable list of candidate nodes from the
    /// active scope, grouped by substrate cluster when available.
    /// Tap-to-toggle selection; pre-seeded with the most recently
    /// updated nodes within the scope as a starting point. Each cluster
    /// section header offers a Select all affordance.
    ///
    /// Substrate ranking by cosine similarity to recent activity is the
    /// design target (per brief); recency seeding is the c8.2 proxy
    /// until the substrate-similarity service surfaces a public API.
    @ViewBuilder
    private func researchSelectStage(librarian: LibrarianState) -> some View {
        let candidates = researchCandidates(librarian: librarian)
        let groups = researchClusterGroups(candidates: candidates)

        VStack(spacing: 0) {
            if candidates.isEmpty {
                researchStubStage(
                    title: "No nodes in scope",
                    detail: "Switch scope above to pick nodes from a different slice of the corpus."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        ForEach(groups, id: \.label) { group in
                            researchClusterSection(group: group, librarian: librarian)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .floatingPanelScrollTracking(proxy: proxy)

                researchSelectFooter(librarian: librarian)
            }
        }
        .onAppear { researchSeedSelectionIfNeeded(librarian: librarian, candidates: candidates) }
        .onChange(of: librarian.selectedScope) { _, _ in
            researchSeedSelectionIfNeeded(librarian: librarian, candidates: candidates)
        }
    }

    /// Source list for Stage 1 — every node in the active scope, sorted
    /// by `updatedAt` descending so the top of the list is what the user
    /// has been working on most recently.
    private func researchCandidates(librarian: LibrarianState) -> [Node] {
        store.nodes(in: librarian.selectedScope)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Section model — one per cluster (or one "Unclustered" bucket when
    /// substrate placements aren't available yet). `clusterID` is the
    /// raw HDBSCAN label or `nil` when substrate wasn't consulted; the
    /// label is what gets rendered.
    private struct ResearchClusterGroup {
        let label: String
        let clusterID: Int?
        let nodes: [Node]
    }

    /// Group candidates by substrate cluster. Falls back to a single
    /// "All notes" bucket when no placements exist (small corpus, pre-
    /// fit, or the substrate service isn't loaded). Noise nodes (cluster
    /// `-1`) land in their own "Outliers" bucket so the user can still
    /// reach them but the visual separation matches the canvas.
    private func researchClusterGroups(candidates: [Node]) -> [ResearchClusterGroup] {
        guard let placements = SubstrateLayoutService.shared.canvasPlacements(),
              !placements.isEmpty else {
            return [ResearchClusterGroup(label: "All notes", clusterID: nil, nodes: candidates)]
        }
        let clusterByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: placements.map { ($0.nodeID, $0.clusterID) }
        )
        var buckets: [Int?: [Node]] = [:]
        for node in candidates {
            let cluster = clusterByID[node.id]
            buckets[cluster, default: []].append(node)
        }
        // Stable ordering: real clusters first (by ID asc), then noise (-1),
        // then "unplaced" (nodes the substrate hasn't seen yet) so the user's
        // most recent captures don't disappear into a trailing tail.
        let realClusters = buckets.keys.compactMap { $0 }.filter { $0 >= 0 }.sorted()
        var ordered: [ResearchClusterGroup] = []
        for id in realClusters {
            guard let nodes = buckets[id] else { continue }
            ordered.append(ResearchClusterGroup(label: "Cluster \(id + 1)", clusterID: id, nodes: nodes))
        }
        if let noise = buckets[-1] {
            ordered.append(ResearchClusterGroup(label: "Outliers", clusterID: -1, nodes: noise))
        }
        if let unplaced = buckets[nil] {
            ordered.append(ResearchClusterGroup(label: "Recently added", clusterID: nil, nodes: unplaced))
        }
        return ordered
    }

    @ViewBuilder
    private func researchClusterSection(group: ResearchClusterGroup, librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                Text("\(group.nodes.count)")
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                Button {
                    toggleSelectAllInCluster(group: group, librarian: librarian)
                } label: {
                    Text(allSelected(in: group, librarian: librarian) ? "Deselect all" : "Select all")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            ForEach(group.nodes, id: \.id) { node in
                researchCandidateRow(node: node, librarian: librarian)
            }
        }
    }

    @ViewBuilder
    private func researchCandidateRow(node: Node, librarian: LibrarianState) -> some View {
        let isSelected = librarian.researchSelectedNodeIDs.contains(node.id)
        Button {
            if isSelected {
                librarian.researchSelectedNodeIDs.remove(node.id)
            } else {
                librarian.researchSelectedNodeIDs.insert(node.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? Color(hexString: "00BFFF") : .white.opacity(0.3))
                    .frame(width: 22, height: 22)

                Circle()
                    .fill(researchNodeColor(node))
                    .frame(width: 8, height: 8)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title.isEmpty ? "Untitled" : node.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.8))
                        .lineLimit(1)
                    if let snippet = researchSnippet(node: node), !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func researchSelectFooter(librarian: LibrarianState) -> some View {
        let count = librarian.researchSelectedNodeIDs.count
        HStack(spacing: 12) {
            Text(count == 0 ? "No nodes selected" : "\(count) selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(count == 0 ? 0.4 : 0.85))
            Spacer()
            Button {
                librarian.researchStage = .frame
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(count == 0 ? .white.opacity(0.3) : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(count == 0 ? Color.white.opacity(0.06) : Color.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    /// Tag-derived color, mirroring `NodePickerSheet.nodeColor`. The
    /// substrate-color path (`SubstrateLayoutService.colorHSB`) is
    /// canvas-only — Stage 1 reads with the same primitive every other
    /// node-list surface uses so the dot doesn't drift between views.
    private func researchNodeColor(_ node: Node) -> Color {
        guard let tag = node.tags.first,
              let storeTag = store.tags.first(where: { $0.name == tag })
        else { return .gray.opacity(0.6) }
        return Color(hex: storeTag.colorHex) ?? .gray.opacity(0.6)
    }

    /// Two-line preview text. Pulls from `summary` first (the AI-derived
    /// gist), falling back to the first item carrying text content,
    /// falling back to nil. Pre-trimmed to keep the row light even on
    /// long notes.
    private func researchSnippet(node: Node) -> String? {
        if !node.summary.isEmpty { return node.summary }
        for item in node.items {
            if let content = item.content, !content.isEmpty {
                return String(content.prefix(240))
            }
        }
        return nil
    }

    private func allSelected(in group: ResearchClusterGroup, librarian: LibrarianState) -> Bool {
        guard !group.nodes.isEmpty else { return false }
        return group.nodes.allSatisfy { librarian.researchSelectedNodeIDs.contains($0.id) }
    }

    private func toggleSelectAllInCluster(group: ResearchClusterGroup, librarian: LibrarianState) {
        if allSelected(in: group, librarian: librarian) {
            for node in group.nodes {
                librarian.researchSelectedNodeIDs.remove(node.id)
            }
        } else {
            for node in group.nodes {
                librarian.researchSelectedNodeIDs.insert(node.id)
            }
        }
    }

    /// Seeds an initial selection when first entering Stage 1 (or when
    /// scope changes). Picks the top-5 most-recently-updated candidates
    /// as the substrate-recency proxy. Does nothing when the scope key
    /// already matches the last seeded key — preserving the user's
    /// explicit edits across collapse/expand and stage navigation.
    private static let researchSeedCount = 5
    private func researchSeedSelectionIfNeeded(librarian: LibrarianState, candidates: [Node]) {
        let key = librarian.selectedScope.key
        guard librarian.researchLastSeededScopeKey != key else { return }
        librarian.researchLastSeededScopeKey = key
        librarian.researchSelectedNodeIDs.removeAll()
        let seeds = candidates.prefix(Self.researchSeedCount)
        for node in seeds {
            librarian.researchSelectedNodeIDs.insert(node.id)
        }
    }

    @ViewBuilder
    private func researchStubStage(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "graduationcap")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scope chips

    /// Horizontal chip row above the input. Tap selects a scope; the
    /// selection is the source of truth for retrieval (Navigate + Ask).
    /// Order mirrors `CollectionPillRail`: Corpus and Journal first
    /// (system slices), then user collections most-recently-used first.
    @ViewBuilder
    private func scopeChipRow(librarian: LibrarianState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeChip(scope: .corpus, label: "Corpus", librarian: librarian)
                scopeChip(scope: .collection(NodeCollection.journalID), label: "Journal", librarian: librarian)
                ForEach(userCollectionsByLastUsed, id: \.id) { collection in
                    scopeChip(
                        scope: .collection(collection.id),
                        label: collection.name,
                        librarian: librarian
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var userCollectionsByLastUsed: [NodeCollection] {
        store.collections.sorted { a, b in
            let aDate = store.collectionLastUsedAt[a.id] ?? .distantPast
            let bDate = store.collectionLastUsedAt[b.id] ?? .distantPast
            return aDate > bDate
        }
    }

    @ViewBuilder
    private func scopeChip(scope: CanvasScope, label: String, librarian: LibrarianState) -> some View {
        let isSelected = librarian.selectedScope == scope
        Button {
            librarian.selectedScope = scope
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? Color.white : Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Seeds `selectedScope` from the host the first time the surface
    /// appears in that host. Tracks the last-seeded host key on
    /// `LibrarianState` so within a single host the user's explicit
    /// chip selection survives remounts. Crossing into a different
    /// host (Corpus → Reading collection, say) re-seeds.
    private func seedScopeFromHostIfNeeded(librarian: LibrarianState) {
        let key = hostScope.key
        guard librarian.lastSeededHostKey != key else { return }
        librarian.selectedScope = hostScope
        librarian.lastSeededHostKey = key
    }

    // MARK: - Animations

    private func startWhisperCycle() {
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            cycleWhisper()
        }
    }

    private func cycleWhisper() {
        withAnimation(.easeInOut(duration: 0.6)) {
            textOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let count = activeWhispers.count
            guard count > 0 else { return }
            currentWhisperIndex = (currentWhisperIndex + 1) % count

            withAnimation(.easeInOut(duration: 0.6)) {
                textOpacity = 0.55
            }
        }
    }
}

// MARK: - Search result rows

/// MATCHES row — node title prominently, scope/tag hint underneath.
/// Tap-through wiring lands in C3; visual stub today renders title +
/// summary preview without navigation.
private struct SearchMatchRow: View {
    let node: Node

    private var snippet: String {
        if let s = node.substrateSummary, !s.isEmpty { return s }
        return node.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.title.isEmpty ? "Untitled" : node.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// RELATED row — node title above, NLTokenizer-extracted pull quote
/// from the matched block below. Pull quote is pre-trimmed and
/// length-capped at compute time so the row stays bounded.
private struct SearchRelatedRow: View {
    let node: Node
    let snippet: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(node.title.isEmpty ? "Untitled" : node.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// Silent pre-token indicator. Shown from request-fired until the
/// first streamed delta arrives. Pulses opacity so the user has
/// continuous feedback that work is happening — distinct from the
/// blinking cursor that takes over once tokens flow.
private struct ThinkingShimmerView: View {
    @State private var opacity: Double = 1.0

    var body: some View {
        Text("Thinking…")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.55))
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    opacity = 0.25
                }
            }
    }
}

/// Streaming cursor — quiet blinking caret rendered at the tail of
/// the streamed text. Mounted only while `isStreaming && !streamingText.isEmpty`
/// so it disappears the moment the stream completes.
private struct StreamingCursorView: View {
    @State private var visible: Bool = true

    var body: some View {
        Text("▋")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.55))
            .opacity(visible ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

