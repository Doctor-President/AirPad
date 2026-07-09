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
/// so the host NavigationStack (CanvasView / VerticalScrollView) owns the
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
    @State private var presentedCitation: PresentedCitation? = nil
    @State private var showEndDialog = false
    @State private var isSavingSession = false
    @State private var researchExportCopied = false
    /// Ask chat/home toggle. False → Librarian home (capability-tile
    /// launchpad + active-chat pill). True → the active `router.chat`
    /// transcript. Only meaningful when `activeMode == .ask`; set true on
    /// send / active-chat-pill tap, false on Back.
    @State private var isViewingActiveChat = false
    /// Drives the active-chat pill's × → "Save or Delete" dialog.
    @State private var showChatDisposition = false
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

        // GeometryReader exposes the LIVE surface size, which under
        // FloatingPanel's `.fitToBounds` re-fits per detent and grows
        // continuously during drag. The morphing field positions itself
        // against this live size so the field rides the panel's height
        // change as p climbs from 0→1.
        GeometryReader { geo in
            ZStack {
                // Panel material — Solar Flare layered look (tuner-driven
                // base + dark tint + optional rotating prismatic edge).
                // Faded via PeekFadeLayer (observes the isolated morph
                // model) so the peek posture shows only the morphing
                // field's Liquid Glass; the panel-wide material rises with
                // the chrome. The -150pt bottom buffer + edge-vs-fill
                // split live inside `SolarFlareMaterial`. Drag-gate flips
                // off the rotating edge during finger-drag to keep the
                // live motion cheap.
                PeekFadeLayer(
                    progress: panelModel.progress,
                    content: SolarFlareMaterial(isDragging: panelModel.isDragging,
                                                activeAccent: activeAccent)
                        .allowsHitTesting(false)
                )

                // Born-in chrome. Header + chips + transcript/results
                // + input row + footer. The search field is NOT in here
                // — it's the morphing field overlaid on top, which lands
                // in the chrome's reserved slot at p=1. Faded via
                // PeekFadeLayer; heavy subtrees inside mount on
                // `contentRevealed` (p>0.4 crossing) so transcript/results
                // don't render while the panel is still at peek.
                PeekFadeLayer(
                    progress: panelModel.progress,
                    content: expandedChrome(librarian: librarian)
                        .allowsHitTesting(panelModel.contentRevealed)
                )

                // THE morphing field. Single view that is both the peek
                // pill and the expanded search field; never swapped,
                // only its frame / position / corner interpolate against
                // p. Position uses `geo.size` so the field tracks the
                // panel's live height. At p=0 it's the baked Maps pill
                // (340 × 64, corner 45, 21pt above safe area). At p=1
                // it's a full-width rounded field (~52pt tall, corner
                // 16) just below the chrome's header. Fed the live
                // per-frame value via PeekProgressReader's isolated
                // subtree so the parent body stays quiet during drag.
                PeekProgressReader(progress: panelModel.progress) { p in
                    morphingField(geo: geo, librarian: librarian, p: p)
                }

            }
        }
        .onAppear {
            startWhisperCycle()
            seedScopeFromHostIfNeeded(librarian: librarian)
        }
        .task {
            // Continue-by-default across launches: hydrate the shared
            // chat lane from the most-recent stored conversation on cold
            // launch. Internally guarded (`didRestore`) so it's a no-op
            // once any chat activity exists — safe to call alongside
            // ChatView's own restore.
            await router.chat.restoreIfNeededFromStore()
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
                // Leaving .full leaves the chat — a drag-down is a
                // deliberate exit, identical to Back. Clearing the flag
                // here means re-entry requires an explicit action (pill
                // tap or send); dragging back UP to full shows the home,
                // never a silently re-mounted transcript (which sputtered
                // mid-animation). `state` publishes settled detents only,
                // so this can't misfire while raising TO full on entry:
                // entry sets the flag then expandToFull, and the observer
                // sees the settled .full → does nothing.
                isViewingActiveChat = false
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

        // Y-position interpolation. Peek anchor: `peekBottomGap` above the
        // panel bottom (so the field's bottom edge sits at
        // geo.height − peekBottomGap). Shared with `peekDetentHeight` so
        // the capsule and the band reserving space for it move together.
        // Expanded anchor: anchors a few points inside the header's
        // bottom-padding band so the Search field sits snug to the
        // chevron (chevron bottom ≈ y=46; field top at y=54 with this
        // anchor → ~8pt gap). The header ZStack itself runs ~60pt tall,
        // but the bottom 14pt is empty padding the field can ride into
        // without colliding with chevron/grabber visuals.
        let peekCenterY = geo.size.height - LibrarianPanelLayout.peekBottomGap - peekH / 2
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
    private func expandedChrome(librarian: LibrarianState) -> some View {
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
                    // Provisional compose glyph removed (FIX 3). New-chat
                    // returns later in proper header grammar;
                    // `router.chat.startNew()` stays intact and new/switch
                    // chats remain reachable via the Chats tile.
                    Spacer()

                    // TEMP (3a) — manual lock trigger so 3a's panel
                    // mechanics can be exercised on device. 3b replaces
                    // this with the Ask-input → `lockToFull` pipeline
                    // and removes the button. Visible only when NOT
                    // already locked.
                    if !panelModel.isLocked {
                        Button {
                            panelModel.lockToFull(animated: true)
                        } label: {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }

                    if panelModel.isLocked {
                        // Locked-state collapse exit. Always visible while
                        // locked so the way out is discoverable at a
                        // glance. Tap → `unlock(animated:)` clears the
                        // lock and animates to `.half`. Filled-circle
                        // backdrop + brighter opacity than the unlocked
                        // chevron so it reads as a primary affordance
                        // rather than chrome.
                        Button {
                            panelModel.unlock(animated: true)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle().fill(Color.white.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    } else {
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

            // Scope-chip row removed (FIX 2). Scope still defaults from
            // the host context via `seedScopeFromHostIfNeeded`; only the
            // UI row is gone. `scopeChipRow` is left defined for a
            // separate dead-code cleanup pass.

            // Perf gate. Below the p=0.4 crossing the chrome is fully
            // invisible (PeekFadeLayer opacity = 0 until p=0.5) and the
            // morphing field covers the visible area anyway — skip
            // building the heavy transcript / search-results / research
            // subtrees so a drag tick stays cheap. `contentRevealed`
            // flips once at the crossing instead of being re-gated every
            // frame.
            if panelModel.contentRevealed {
                if !librarian.searchText.isEmpty {
                    // Search takes over the main pane while the field has
                    // content — instant MATCHES (C1) and RELATED (C2)
                    // render in place of the mode pipeline's transcript.
                    // Clearing the field restores the pipeline UI.
                    searchResultsView(librarian: librarian)
                        .frame(maxHeight: .infinity)
                } else {
                    // Conversation transcript (flexes), input row beneath
                    // it — chat-app convention so new messages land near
                    // the typing area. Ask routes to the clean ChatSession
                    // lane (passage-free, durable per-turn persistence):
                    // home (tile launchpad + active-chat pill) vs. the
                    // active chat transcript. The transcript is gated on
                    // BOTH `isViewingActiveChat` AND the expanded (.full)
                    // posture — the invariant is transcript ⟺
                    // (isViewingActiveChat && panel expanded), so at half
                    // (or below) the home always shows, never the
                    // transcript peeking. `state` is the authoritative
                    // expanded signal (peekProgress saturates at 1 for both
                    // half and full, so it can't distinguish them). Every
                    // other mode keeps the corpus pipeline transcript.
                    if isViewingActiveChat && panelModel.state == .full {
                        chatTranscriptView()
                            .frame(maxHeight: .infinity)
                        // Endpoint/network failures surface here as a
                        // transient banner above the input row — never as
                        // an assistant bubble in the transcript.
                        if let error = router.chat.lastError {
                            chatErrorBanner(message: error)
                        }
                    } else {
                        librarianHome(librarian: librarian)
                            .frame(maxHeight: .infinity)
                    }

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

            // Back pill. In Ask it exits the active chat back to home, so
            // it rides with the transcript — shown only when the transcript
            // is (isViewingActiveChat && expanded). At half the home shows
            // "home only" with no stray Back pill. In the other modes it
            // stays the quickfix panel-collapse affordance. The old
            // `endSessionFooter` / End-session dialog remain dormant for a
            // separate dead-code cleanup pass.
            if isViewingActiveChat && panelModel.state == .full {
                backPill()
            }
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
        // Active-chat pill × → keep or discard the live chat. Save
        // persists it to the Chats list and resets to an empty session;
        // Delete removes it for good. Both leave the session empty so the
        // pill clears.
        .confirmationDialog(
            "Save or delete this chat?",
            isPresented: $showChatDisposition,
            titleVisibility: .visible
        ) {
            Button("Save") {
                // Flush + persist the current chat, then reset to a fresh
                // empty session. The chat stays in the Chats list.
                router.chat.startNew()
            }
            Button("Delete", role: .destructive) {
                // Same order as the Chats-list delete: startNew() flushes
                // + resets the live session, then delete(id:) tombstones
                // the old chat so the lagging flush can't resurrect it.
                let currentID = router.chat.id
                router.chat.startNew()
                router.chatStore.delete(id: currentID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save keeps this chat in your Chats list. Delete removes it permanently.")
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

    /// Bottom Back pill. Exits the active chat back to the Librarian home
    /// and drops the panel to `.half`, touching NO session state — the
    /// Ask chat lane auto-persists per turn (`ChatSession.flush`), so
    /// leaving is "persist, not kill." Left-anchored with a left-pointing
    /// chevron to read as "back out" rather than "collapse." In non-Ask
    /// modes the `isViewingActiveChat = false` is a harmless no-op and the
    /// pill is just the quickfix panel-collapse affordance.
    @ViewBuilder
    private func backPill() -> some View {
        HStack {
            Button {
                isViewingActiveChat = false
                panelModel.dropToHalf(animated: true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Librarian home")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
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
        let hasText = !librarian.inputText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText else { return false }
        // Ask routes through the clean ChatSession lane, so its in-flight
        // gate is the session's `isStreaming`.
        return !router.chat.isStreaming
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
    /// detail-view push is owned by `CanvasView` / `VerticalScrollView`,
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
            // Ask identity glyph. Ask is the only mode now, so this is a
            // static glyph, not a mode switcher (the dropdown is retired).
            modeIconWithRing(librarian: librarian, compact: true)
                // 2pt leading nests the 44pt ring concentrically inside
                // the capsule's left rounded end.
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
                        // Clean ChatSession lane. send() appends the user
                        // message itself + auto-persists per turn, so just hand
                        // off the text and clear the field. Sending enters the
                        // active chat from home: raise to full so the transcript
                        // is visible per the expanded-posture invariant.
                        let text = librarian.inputText
                        librarian.inputText = ""
                        isViewingActiveChat = true
                        panelModel.expandToFull(animated: true)
                        Task { await router.chat.send(text) }
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

    // MARK: - Ask chat lane (ChatSession)

    /// Bottom-anchor sentinel for the Ask chat transcript. Distinct from
    /// the pipeline transcript's anchor so the two scroll views never
    /// fight over the same id.
    private static let chatTranscriptBottomAnchor = "_chat_transcript_bottom"

    /// Ask-mode conversation pane, backed by the clean `router.chat`
    /// (`ChatSession`) lane — no corpus passages, no citations. Renders
    /// each committed message plus the in-flight tail, mirroring
    /// `ChatView`'s scroll/stream grammar while reusing the Librarian's
    /// own bubble styling (`transcriptQueryBubble` + `attributedMarkdown`).
    /// Shown only while `isViewingActiveChat` is true — the empty /
    /// first-open state now lives on `librarianHome`, so no tile fallback
    /// here.
    @ViewBuilder
    private func chatTranscriptView() -> some View {
        let chat = router.chat
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(chat.messages) { message in
                        chatBubble(message)
                            .id(message.id)
                    }

                    if chat.isStreaming {
                        chatInflightTail()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.chatTranscriptBottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    scrollProxy.scrollTo(Self.chatTranscriptBottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: chat.streamingText) { _, _ in
                // Stream-follow: chase the tail per delta, no animation
                // (token cadence is already smooth; animating per-delta
                // stutters) — mirrors the pipeline transcript.
                scrollProxy.scrollTo(Self.chatTranscriptBottomAnchor, anchor: .bottom)
            }
            .onAppear {
                scrollProxy.scrollTo(Self.chatTranscriptBottomAnchor, anchor: .bottom)
            }
            .floatingPanelScrollTracking(proxy: proxy)
        }
    }

    /// Ask-mode Librarian home — the capability-tile launchpad (compressed
    /// to a single row) plus, when a conversation exists, the active-chat
    /// pill that jumps back into it. This is the landing surface when
    /// `isViewingActiveChat` is false; Back returns here from the
    /// transcript.
    @ViewBuilder
    private func librarianHome(librarian: LibrarianState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                capabilityTileGrid(librarian: librarian, singleRow: true)

                // Active-chat pill — the one-tap breadcrumb back into the
                // live conversation. Only when the chat has messages
                // ("one pill at a time" — the single live session).
                if !router.chat.messages.isEmpty {
                    activeChatPill()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .floatingPanelScrollTracking(proxy: proxy)
    }

    /// Active-chat pill on the Ask home. Body tap resumes the live
    /// `router.chat`; trailing × opens the keep/discard dialog. Title
    /// tracks `displayTitle` (FM title once it lands, truncation
    /// fallback before).
    @ViewBuilder
    private func activeChatPill() -> some View {
        HStack(spacing: 10) {
            Button {
                // Resume the chat: raise to full so the transcript shows
                // (transcript ⟺ isViewingActiveChat && expanded), never a
                // blank half.
                isViewingActiveChat = true
                panelModel.expandToFull(animated: true)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hexString: "00BFFF"))
                    Text(router.chat.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume chat: \(router.chat.displayTitle)")

            Button {
                showChatDisposition = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
    }

    /// One committed chat message. User turns reuse the Librarian's
    /// right-aligned query bubble; assistant turns reuse the same
    /// inline-markdown body as the pipeline transcript (shared
    /// `attributedMarkdown` cache).
    @ViewBuilder
    private func chatBubble(_ message: ChatSession.Message) -> some View {
        switch message.role {
        case .user:
            transcriptQueryBubble(text: message.text)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                Text(attributedMarkdown(message.text))
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                // Per-turn read-aloud — every settled assistant turn is
                // independently replayable (Claude's model). Not added to
                // the in-flight tail; matches the old pipeline transcript.
                chatReadAloudControl(message: message)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Read-aloud control for a settled assistant chat turn. Re-wires the
    /// existing `SpeechSynthesisService` (same glyphs, placement, and call
    /// pattern the old Ask pipeline used in `transcriptResponseBody`) —
    /// including its lock-screen / Now-Playing plumbing. The per-message
    /// UUID is the speech token, so each turn's play/pause is independent.
    @ViewBuilder
    private func chatReadAloudControl(message: ChatSession.Message) -> some View {
        if !message.text.isEmpty {
            let token = message.id.uuidString
            let isActive = speech.activeToken == token
            let showPause = isActive && speech.isSpeaking && !speech.isPaused
            let voiceSelection = Binding<String?>(
                get: { speech.selectedVoiceIdentifier },
                set: { speech.selectedVoiceIdentifier = $0 }
            )
            HStack(spacing: 14) {
                Button {
                    speech.toggle(token: token, text: message.text)
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

    /// In-flight tail for the Ask chat lane. Mounted only while the
    /// session is streaming. Pre-token → pulsing shimmer; mid-stream →
    /// raw streamed text + blinking cursor (raw, not markdown, to avoid
    /// re-parsing partial markdown per delta — same choice as the
    /// pipeline's `inflightAnswerTail`).
    @ViewBuilder
    private func chatInflightTail() -> some View {
        let chat = router.chat
        if !chat.streamingText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.streamingText)
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

    /// Transient endpoint-failure banner for the Ask chat lane. Renders a
    /// distinct, non-message error state (amber, Retry + dismiss) so a
    /// failed send never lands in the transcript as an assistant bubble.
    /// Retry re-sends the trailing user turn; × clears the banner.
    @ViewBuilder
    private func chatErrorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hexString: "E8820A"))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await router.chat.retryLastUserTurn() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hexString: "00BFFF"))
            .buttonStyle(.plain)
            .disabled(router.chat.isStreaming)
            Button {
                router.chat.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hexString: "E8820A").opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(hexString: "E8820A").opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.top, 4)
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


    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium:  q = "Premium"
        case .enhanced: q = "Enhanced"
        default:        q = "Default"
        }
        return "\(v.name) — \(q)"
    }


    /// Cache of parsed markdown, keyed by the raw response text.
    /// Committed exchange text is immutable, so a given string always
    /// parses to the same AttributedString — caching it stops the
    /// transcript from re-parsing every response on every drag frame
    /// (peekProgress changes per-frame → body re-runs → transcript
    /// rebuilds → this was re-parsing N essays at 60fps).
    private static var markdownCache: [String: AttributedString] = [:]

    private func attributedMarkdown(_ text: String) -> AttributedString {
        if let cached = Self.markdownCache[text] { return cached }
        let result: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            result = parsed
        } else {
            result = AttributedString(text)
        }
        // Soft cap — sessions rarely exceed this many distinct
        // responses; clear-all on overflow is fine (worst case a few
        // re-parses, not a per-frame leak).
        if Self.markdownCache.count > 200 {
            Self.markdownCache.removeAll(keepingCapacity: true)
        }
        Self.markdownCache[text] = result
        return result
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

    /// 2×2 grid that occupies the landing pocket (no session, empty
    /// search) in place of the retired "Try Asking" suggestions list.
    /// Frames the Librarian as a launchpad into Insights / Inbox /
    /// Capsule / Chats instead of a dead suggestion list.
    ///
    /// Tap destinations are stubbed this pass — the workstreams that
    /// own each surface (corpus reflection, Inbox SB134, chat
    /// primitive, capsule export) wire them up as they land. Capsule
    /// renders dimmed + inert until its export format is locked.
    /// `singleRow` compresses the four tiles into one row of compact
    /// cards (the Ask home, which needs vertical room beneath for the
    /// active-chat pill). Default false keeps the 2×2 grid used by the
    /// pipeline-mode empty landing.
    @ViewBuilder
    private func capabilityTileGrid(librarian: LibrarianState, singleRow: Bool = false) -> some View {
        if singleRow {
            HStack(spacing: 10) {
                capabilityTiles(compact: true)
            }
        } else {
            let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]
            LazyVGrid(columns: columns, spacing: 12) {
                capabilityTiles(compact: false)
            }
        }
    }

    /// The four landing tiles, shared by both the 2×2 grid and the
    /// single-row home layout. `compact` shrinks each card so all four
    /// fit one row.
    @ViewBuilder
    private func capabilityTiles(compact: Bool) -> some View {
        capabilityTile(
            label: "Insights",
            systemImage: "sparkles",
            isEnabled: true,
            compact: compact
        ) {
            // TODO: route to corpus-reflection workstream
        }
        capabilityTile(
            label: "Inbox",
            systemImage: "tray",
            isEnabled: true,
            compact: compact
        ) {
            // TODO: route to dashboard Inbox surface (SB134).
            // Future badge count slot lives on this tile.
        }
        capabilityTile(
            label: "Capsule",
            systemImage: "shippingbox",
            isEnabled: false,
            compact: compact
        ) {
            // Dimmed + inert until export format is locked.
        }
        capabilityTile(
            label: "Chats",
            systemImage: "bubble.left.and.bubble.right",
            isEnabled: true,
            compact: compact
        ) {
            // Drop to .half first so a full-detent Librarian doesn't
            // present the sheet from behind itself — mirrors the
            // `openNode` handoff pattern above.
            panelModel.dropToHalf(animated: true)
            router.showChatsList = true
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
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let card = VStack(spacing: compact ? 6 : 10) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 18 : 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text(label)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 12 : 18)
        .padding(.horizontal, compact ? 8 : 16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 14))

        if isEnabled {
            Button(action: action) { card }
                .buttonStyle(.plain)
        } else {
            card.opacity(0.4)
        }
    }

    // MARK: - Research mode (c8)


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

/// Re-applies a peekProgress-derived opacity over BUILD-ONCE content. Parent builds the
/// content once and stores it; only this wrapper re-evaluates per frame (it observes the
/// isolated MorphProgressModel) and all it does is change `.opacity()` — a cheap
/// composite, NOT a rebuild. This keeps the SolarFlareMaterial blur + the chrome out of
/// the per-frame path.
private struct PeekFadeLayer<Content: View>: View {
    @ObservedObject var progress: MorphProgressModel
    let content: Content
    var body: some View {
        content.opacity(max(0, (progress.peekProgress - 0.5) / 0.5))
    }
}

/// Hands the live per-frame peekProgress to a builder in an ISOLATED subtree. Only this
/// view re-evaluates per frame; the parent body does not (it doesn't observe the morph
/// model). Used by the morphing field, which genuinely needs the continuous value.
private struct PeekProgressReader<V: View>: View {
    @ObservedObject var progress: MorphProgressModel
    @ViewBuilder let build: (CGFloat) -> V
    var body: some View { build(progress.peekProgress) }
}

