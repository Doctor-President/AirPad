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
    // @Observable (per-property tracking): the body re-evaluates only when a
    // property it actually reads changes — `state` (≈3×/drag) — NOT the
    // per-frame `progress.peekProgress`, which only the chrome leaves read.
    // This is the root perf fix: the old `@ObservedObject` invalidated the
    // whole body on ANY published change (peekProgress fires ~60×/sec).
    let panelModel: LibrarianPanelStateModel
    let proxy: FloatingPanelProxy

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var presentedCitation: PresentedCitation? = nil
    @State private var researchExportCopied = false
    /// Ask chat/home toggle. False → Librarian home (capability-tile
    /// launchpad + active-chat pill). True → the active `router.chat`
    /// transcript. Only meaningful when `activeMode == .ask`; set true on
    /// send / active-chat-pill tap, false on Back.
    @State private var isViewingActiveChat = false

    // #1-followup (chat chrome reclaim) — scroll offset from the transcript
    // top; drives the scroll-collapsing chat title's opacity.
    @State private var chatScrollTopOffset: CGFloat = 0

    // #1-followup chat-chrome values — BAKED from the DEBUG tuner (T-dialed,
    // settled 2026-07-29; the tuner panel + button were deleted). Plain literals:
    // top gap of the reclaimed chat header · top/bottom transcript fade fractions
    // · scroll distance the collapsing title fades in over · title point size ·
    // bottom-chrome inset under the backPill.
    private let cctTopGap: Double = 6
    private let cctTopFade: Double = 0.06
    private let cctBottomFade: Double = 0.06
    private let cctTitleCollapse: Double = 64
    private let cctTitleSize: Double = 15
    private let cctBottomInset: Double = 10
    /// Drives the active-chat pill's × → "Save or Delete" dialog.
    @State private var showChatDisposition = false
    /// ws-chat-lane — presents `PinChatSheet` for the active chat (the pill's pin
    /// button; the Librarian is the third pin entry point).
    @State private var showingLibrarianPinSheet = false
    /// STATE 2 — routes the "no model for chat" notice into Settings (same pattern as the
    /// lever's capability-boundary banner: CanvasChrome / DashboardView / LeverTray).
    @State private var showSettings = false
    @FocusState private var isInputFocused: Bool
    /// Live measured height of the Ask field (grows with wrapped lines). Drives
    /// the Messages-style corner: `min(height/2, singleLineHeight/2)` — a PILL at
    /// one line, pinning to the single-line half-height (→ rounded rect) as it
    /// grows. Shared by the field shape AND its focus glow so they can't disagree.
    @State private var askFieldHeight: CGFloat = LibrarianSurface.askSingleLineHeight
    /// The Ask field's single-line height (`.frame(minHeight:)`). Half of it is
    /// the pinned corner radius once the field wraps.
    static let askSingleLineHeight: CGFloat = 52
    /// Messages-style corner from the live height: capsule at one line (radius =
    /// half-height), pinned to `askSingleLineHeight/2` (=26) once it grows taller.
    private var askCornerRadius: CGFloat {
        min(askFieldHeight / 2, LibrarianSurface.askSingleLineHeight / 2)
    }
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

    // #2 — the peek-pill masked "inner glow" flare (SolarFlarePeekFlare +
    // `sf.peekFlare*`) was REMOVED. The pill's appearance is now the typed
    // per-mode `PeekPillStyle` (material + tint + shadow-caster shadow/glow +
    // stroke), applied via `.peekPillBackground(_:)` at the morphingField mount.

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

    /// BUG 11 — race-proof suppression gate. The panel POSITION duck driven from
    /// ContentView can be raced on a warm canvas→capture transition (the peek
    /// pill can bleed into the capture editor / QuikCapture on device). This
    /// mirrors ContentView's `librarianSuppressed` SSOT but lives HERE, where the
    /// `@Environment(AppRouter.self)` body re-evaluates reactively on every
    /// `isCapturing`/`entryMode` change — so the surface renders empty + inert
    /// whenever a canvas-covering surface is up, regardless of where the panel
    /// physically sits. Canvas / collection-canvas show the peek as normal.
    private var panelSuppressed: Bool {
        if router.isCapturing { return true }
        switch router.entryMode {
        case .canvas, .collectionCanvas:
            return false
        case .quikCapture:
            return true
        case .dashboard, .recents:
            // BUG 15 — mirror ContentView.librarianSuppressed's Detail exemption.
            // The dashboard / recents LIST surfaces suppress the whole surface,
            // but a node DETAIL pushed from them is a canvas-like surface where
            // the Librarian belongs. Without this, the surface stayed opacity-0
            // in a Recents→Detail even after ContentView raised the panel — the
            // peek pill was POSITIONED but INVISIBLE. Confirmed by device log
            // (2026-07-29): here `panelSuppressed=true` / `surfaceAlpha=0` while
            // `librarianSuppressed=false`, `isViewingActiveChat=false`,
            // `fieldAlpha=1` — i.e. every other gate was already open; this one
            // wasn't. a91a0cd fixed the panel POSITION gate but not this SURFACE
            // OPACITY gate.
            return !store.isInDetailView
        }
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
                // Panel material — PER-MODE (T's decision 2026-07-24: the
                // Librarian is NO LONGER dark-only; the "deliberately dark Solar
                // Flare panel" exclusion is VOID). `LibrarianPanelMaterial` picks
                // by colorScheme (ONE typed selection, the PeekPillStyle pattern —
                // no colorScheme fork here): DARK = the untouched SolarFlareMaterial
                // (byte-identical); LIGHT = the Cucumber Water cream+glass surface
                // (baked values — light tuner deleted). The -150pt bottom buffer +
                // edge-vs-fill split live inside each material. Faded via PeekFadeLayer so the
                // peek posture shows only the morphing field's glass.
                PeekFadeLayer(
                    progress: panelModel.progress,
                    content: LibrarianPanelMaterial(isDragging: panelModel.isDragging,
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
                    // #1 / BUG 14 — while viewing the active chat, fade the
                    // morphing field out ONLY as it expands into the chat chrome
                    // (p → 1). The PEEK PILL (p ≈ 0) stays visible + tappable so
                    // collapsing to peek ALWAYS leaves a way back into the
                    // Librarian. The original c06f88f gate used a blanket
                    // opacity-0 across every posture — so a collapse-to-peek out
                    // of a chat suppressed the pill for the whole process
                    // lifetime and stranded the user (BUG 14). `isViewingActiveChat`
                    // stays set across postures by design (posture-persistent
                    // chat), so the fix is posture-awareness here, NOT clearing
                    // the flag. Not in a chat → always fully shown (unchanged).
                    let fieldOpacity: Double = isViewingActiveChat
                        ? Double(max(0, min(1, (0.5 - p) / 0.5)))
                        : 1
                    morphingField(geo: geo, librarian: librarian, p: p)
                        .opacity(fieldOpacity)
                        .allowsHitTesting(fieldOpacity > 0.01)
                }

            }
        }
        .onAppear {
            startWhisperCycle()
            seedScopeFromHostIfNeeded(librarian: librarian)
            // Resolve the active-model indicator off the render path (Keychain +
            // possible network probe). Refreshed again on Ask-focus so a Settings
            // endpoint swap is reflected before the next turn.
            Task { await librarian.refreshActiveModel() }
            #if DEBUG
            // Real-screen verification hooks for the Ask-field shape/glow pass:
            // `-AskPrefill <text>` fills the Ask field (to see it wrap), `-AskFocus`
            // focuses it (to see the glow). No-ops without the args.
            if let prefill = UserDefaults.standard.string(forKey: "AskPrefill"), !prefill.isEmpty {
                librarian.inputText = prefill
            }
            if UserDefaults.standard.bool(forKey: "AskFocus") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isInputFocused = true }
            }
            // `-AskShrinkTest YES` — the height-shrink proof: fill to 4 lines, then
            // CLEAR after a beat. Screenshot after the clear must show a 1-line
            // pill (proves the field shrinks, not just grows).
            if UserDefaults.standard.bool(forKey: "AskShrinkTest") {
                librarian.inputText = "What is the difference between a gerund and a present participle, and how do I tell them apart when both end in -ing in a sentence?"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { librarian.inputText = "" }
            }
            // `-AskAutoSend <question>` — fires a real Ask through `groundedSend`
            // (honouring the live `corpusAware` mode) so the corpus-aware toggle can
            // be smoke-tested headlessly: screenshot the transcript to see the answer
            // + whether a citation footer appears. Expands to full so the transcript
            // is visible.
            if let q = UserDefaults.standard.string(forKey: "AskAutoSend"), !q.isEmpty {
                isViewingActiveChat = true
                panelModel.expandToFull(animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Task { await librarian.groundedSend(query: q, store: store, chat: router.chat) }
                }
            }
            // `-PersistCorpusAware YES` — flips the toggle ON via the real setter
            // (didSet → UserDefaults), so a SUBSEQUENT launch with no arg proves the
            // preference persisted across an app restart (⊇ a surface remount).
            if UserDefaults.standard.bool(forKey: "PersistCorpusAware") {
                librarian.corpusAware = true
            }
            // `-DeadLinkTest YES` — inject an assistant turn with MODEL-AUTHORED URLs
            // (a markdown link + a bare url + a [1] ref) so `-Screen` can confirm the
            // fabricated URLs render as PLAIN TEXT (de-linked), while the activity-row
            // result links stay real + tappable.
            if UserDefaults.standard.bool(forKey: "DeadLinkTest") {
                isViewingActiveChat = true
                panelModel.expandToFull(animated: false)
                router.chat.debugAppendAssistant(
                    "Two good SpongeBob video essays: [Full Fat Videos on YouTube](https://www.youtube.com/playlist?list=PLfabricated9x8y7z) and one at https://example.com/spongebob-essay-fake — see [1] for the source I used."
                )
            }
            // `-PartialTurnTest YES` — inject a user turn + a PARTIAL assistant turn
            // (BUG 36: the stream dropped mid-answer) so `-Screen` can confirm the calm
            // "Stopped early / Continue" affordance renders on the dropped turn — NOT a
            // red failure banner (the pre-fix behavior discarded the text + errored).
            if UserDefaults.standard.bool(forKey: "PartialTurnTest") {
                isViewingActiveChat = true
                panelModel.expandToFull(animated: false)
                router.chat.debugAppendPartialTurn(
                    user: "Explain how a Cloudflare tunnel keeps my Mac reachable.",
                    partial: "A Cloudflare tunnel works by having a lightweight agent on your Mac dial OUT to Cloudflare's edge, so there's no inbound port to open. Your phone reaches a stable public hostname and Cloudflare routes that request down the"
                )
            }
            // `-BraveDiag YES` — verify the Brave executor without a live subscription:
            // (1) parseBrave on a mock payload → mapped {title,url,snippet}; (2) backend
            // selection given key present/absent; (3) live request wiring (fake key from
            // -BraveTestKey → reaches Brave, real results with T's key). → tmp/bravediag.txt
            if UserDefaults.standard.bool(forKey: "BraveDiag") {
                Task {
                    var out = "=== (1) parseBrave(mock) ===\n"
                    let mock = """
                    {"web":{"results":[
                      {"title":"Chicago <strong>Yoga</strong> Studio","url":"https://example.com/yoga","description":"A welcoming <strong>yoga</strong> studio in the South Loop."},
                      {"title":"Best Coffee in Chicago","url":"https://example.com/coffee","description":"Top roasters &amp; cafes."}
                    ]}}
                    """.data(using: .utf8)!
                    for l in BraveSearchToolExecutor.parseBrave(mock) {
                        out += "  • \(l.title) | \(l.url) | \(l.snippet ?? "-")\n"
                    }
                    out += "\n=== (2) WebSearchBackend.make() selection ===\n"
                    let dbgKey = UserDefaults.standard.string(forKey: "BraveTestKey") ?? ""
                    out += "  -BraveTestKey present=\(!dbgKey.isEmpty) → \(String(describing: type(of: WebSearchBackend.make())))\n"
                    out += "\n=== (3) live Brave request wiring ===\n"
                    let probeKey = dbgKey.isEmpty ? "FAKE-KEY-NO-SUB" : dbgKey
                    out += await BraveSearchToolExecutor.diagnose(query: "chicago yoga", apiKey: probeKey) + "\n"
                    let f = FileManager.default.temporaryDirectory.appendingPathComponent("bravediag.txt")
                    try? out.write(to: f, atomically: true, encoding: .utf8)
                }
            }
            #endif
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
            // The keyboard belongs only at .full (promote-on-focus). Any exit —
            // flick to half, drop to peek, duck to hidden — tears it down. NOTE:
            // this no longer clears `isViewingActiveChat` — the conversation now
            // persists across half/full (Stage 3), so dragging to half keeps the
            // transcript mounted (just resized). Exiting the chat back to home is
            // an explicit action (Back pill / disposition ×).
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
                // About to ask — re-resolve which model will answer, so a Settings
                // endpoint swap is reflected on the next turn (read fresh).
                Task { await librarian.refreshActiveModel() }
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
        // BUG 11 — hard suppression. Empty + inert whenever a canvas-covering
        // surface is up, so a raced position-duck can't leak the peek pill into
        // the capture editor / QuikCapture. Reactive on `router` (see
        // `panelSuppressed`), so it never depends on the panel's physical detent.
        .opacity(panelSuppressed ? 0 : 1)
        .allowsHitTesting(!panelSuppressed)
    }

    /// Surface corner radius — unified at 39pt so the peek pill arc
    /// reads as concentric with the 38pt mode icon ring and the half /
    /// full chrome carries the same arc rather than flattening.
    private var surfaceCornerRadius: CGFloat { 39 }

    /// The RESTING field-definition stroke — shared by BOTH Search and Ask (ws-librarian-cleanup
    /// unified them; they had drifted — Ask carried an always-on adaptive-ink edge, Search a light-only
    /// `#232A2E` that was `.clear` in DARK, so Search had no resting edge on near-black). One gradient,
    /// two instances: `AppearancePalette.ink` (the app's adaptive ink — DARK `#FFFFFF` / LIGHT `#232A2E`)
    /// at α0.22→0.04 top→bottom. Search now GAINS a dark resting edge matching Ask; both then bloom in
    /// their own hue on focus (`SolarFlareFieldGlow`). Search fades this in with detent (`opacity(p)`)
    /// so it hands off cleanly from the peek-pill edge; Ask (no morph) carries it always-on.
    static var restingFieldStroke: LinearGradient {
        LinearGradient(
            colors: [AppearancePalette.ink.opacity(0.22), AppearancePalette.ink.opacity(0.04)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Top-edge drag grabber. Live-tracks vertical drag: the surface
    /// height follows the finger between detents, with a light haptic
    /// pulse at each posture boundary crossed. On release the surface
    /// snaps to the nearest detent and the live offset is animated
    /// back to zero in the same spring as the mode change.
    @ViewBuilder
    private func dragGrabber(librarian: LibrarianState) -> some View {
        Capsule()
            // ws-dark-light-mode item 2 — peek-pill grabber. ink @0.22 (dark
            // #FFFFFF == the old .white@0.22, byte-identical); light = a faint
            // ink blue-black so the handle reads on the light glass. Only the
            // handle is converted here — full Librarian-panel theming is
            // surface 5 (gated on the canvas render-cost item).
            .fill(AppearancePalette.ink.opacity(0.22))
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
            // #2 — the SolarFlarePeekFlare "inner glow" (masked color + dark
            // center) is gone; the pill's material/tint/shadow-glow now come
            // from `.peekPillBackground(outerShape)` below.
            HStack(spacing: 10) {
                // Neutral off-white at rest → Mango when expanded. The pill
                // reads as glass + flare at peek (icon near-white), warming to
                // the Search identity as it grows. Crossfade because
                // foregroundStyle can't lerp a gradient; the existing opacity
                // lerp rides on top.
                ZStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .regular))
                        // #2 FIX 2 — appearance-aware ink (dark #FFFFFF byte-identical,
                        // light dark-ink so the peek icon reads on the light pill).
                        .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                        .opacity(Double(1 - p))
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(mangoGrad)
                        .opacity(Double(p))
                }
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
                    // #2 FIX 2 — entered text: appearance-aware ink (was `.white`,
                    // illegible on the light pill). Dark #FFFFFF byte-identical.
                    .foregroundStyle(AppearancePalette.ink)
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
                                // #2 FIX 2 — appearance-aware ink (dark byte-identical).
                                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
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
                                // Absent at rest → revealed as the pill expands
                                // (p 0.5→1). The resting pill is glass + "Search"
                                // + flare only — no mic.
                                .opacity(Double(max(0, min(1, (p - 0.5) / 0.5))))
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
        // #2 — typed per-mode pill treatment: translucent material + tint + a
        // per-mode shadow/separation (+ optional stroke), baked in PeekPillStyle.
        // The shadow/stroke are scoped to PEEK: `visibility` is 1 at peek (p=0) and
        // fades to 0 by p≈0.35, so the half/full search field carries none of it
        // (material + tint stay).
        .peekPillBackground(outerShape,
                            visibility: max(0, min(1, 1 - Double(p) / 0.35)))
        // Item 4 / ws-librarian-cleanup — the RESTING field-definition stroke, now SHARED with Ask
        // (`restingFieldStroke`). The peek-pill stroke fades out by p≈0.35, so this fades IN as p→1 to
        // define the expanded field's edge — a clean handoff, no double-stroke on the pill. Now present
        // in BOTH appearances (DARK gains the white edge matching Ask; LIGHT is the same #232A2E), so
        // Search and Ask carry one resting treatment; Search's is detent-gated by its morph, Ask's is
        // always-on (no morph).
        .overlay(
            outerShape.strokeBorder(Self.restingFieldStroke, lineWidth: 1)
                .opacity(Double(p))
        )
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

    // #2 — `PeekGlassBackground` was removed; the peek pill's translucency now
    // comes from the typed `PeekPillStyle` (material choice incl. glass) applied
    // via `.peekPillBackground(_:)` (see PeekPillStyle.swift).

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
                // Item 1 (T's call) — REMOVED in the chat view: it collided with
                // the scroll-collapsing title, and Back + the exit chevron cover
                // the affordances there. The panel stays DRAGGABLE — this Capsule
                // hosts no gesture; dragging lives on the FloatingPanel pan
                // recognizer, so only the visual signal goes.
                if !isViewingActiveChat {
                    dragGrabber(librarian: librarian)
                        .padding(.top, 6)
                }

                // Chrome correction 2 — the lock + collapse controls exist ONLY
                // inside the chat interface (the backPill row). On non-chat
                // surfaces (home / search) the header carries no such controls;
                // `lockChevronControls()` stays the single shared source, just
                // not rendered here. (Was briefly top-trailing in 7410dee.)

                // #1-followup item 3 — scroll-collapsing chat title. Absent at
                // scroll-top; fades into the top chrome as the transcript scrolls
                // away (iOS large-title collapse). `displayTitle` always has a
                // real value (first-message truncation within ms, FM title in
                // 2–5s) so there's no blank window and no placeholder needed.
                if isViewingActiveChat {
                    Text(router.chat.displayTitle)
                        // Chrome correction 1 — Source Serif 4 BOLD (the app's
                        // registered serif family; PostScript "SourceSerif4-Bold",
                        // same face as ChatTypography's headings). It reads
                        // optically smaller than the system face, so the tuner's
                        // title-size still needs re-dialing — tuner stays, NOT baked.
                        .font(.custom("SourceSerif4-Bold", size: cctTitleSize))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 44)
                        .padding(.top, 12)
                        .opacity(titleCollapseOpacity)
                        .allowsHitTesting(false)
                }
            }
            .padding(.bottom, isViewingActiveChat ? 4 : 14)
            .contentShape(Rectangle())

            // Reserved slot for the morphing field at p=1. Height
            // matches the field's expandedH (52) + 10pt bottom gap.
            // Trimmed 68→62 to pull the chips + tile grid upward so
            // the bottom row (Capsule / Chats) clears the Ask field
            // at half detent. The field itself is drawn in the `body`
            // overlay; this just holds the pocket.
            // #1-followup item 1 — in an active chat the morphing field is
            // suppressed, so this pocket is dead space; collapse it to a small
            // gap (tunable) and let the transcript extend up into it.
            Color.clear.frame(height: isViewingActiveChat ? cctTopGap : 62)

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
            // POSTURE-PERSISTENT CHAT. When viewing a chat, ChatTranscript is
            // mounted EXACTLY ONCE and stays mounted across ALL postures — peek
            // included — so it is NEVER rebuilt on a posture change. This is the
            // fix for the peek→half stall: the old `contentRevealed` gate
            // unmounted the transcript at peek, so swiping up rebuilt the whole
            // thing before the panel could move. Now the enclosing PeekFadeLayer
            // hides it at peek (opacity 0) and disables its touches
            // (allowsHitTesting(contentRevealed)); presentation changes by
            // posture, never mount state.
            if isViewingActiveChat && librarian.searchText.isEmpty {
                // ChatTranscript owns its own bottom scroll-edge fade at every
                // posture now (chat art-direction pass), so the panel no longer
                // masks it — the placeholder posture mask would have faded out
                // the transcript's footer buttons and scroll-to-latest arrow.
                ChatTranscript(
                    session: router.chat,
                    showsComposer: false,
                    onOpenNode: openNode,
                    topFadeFraction: cctTopFade,
                    bottomFadeFraction: cctBottomFade,
                    onScrollTopOffset: { chatScrollTopOffset = $0 }
                )
                .frame(maxHeight: .infinity)
                askComposer(librarian: librarian)
            } else if panelModel.contentRevealed {
                // Home / search are light — free to mount/unmount with the
                // content-reveal gate (no rebuild-lag concern).
                if !librarian.searchText.isEmpty {
                    searchResultsView(librarian: librarian)
                        .frame(maxHeight: .infinity)
                } else {
                    librarianHome(librarian: librarian)
                        .frame(maxHeight: .infinity)
                }
                askComposer(librarian: librarian)
            } else {
                // Peek with no active chat — hold the vertical flex so the
                // perf-gated swap doesn't collapse the chrome height.
                Spacer(minLength: 0)
            }

            // Back pill. In Ask it exits the active chat back to home, so
            // it rides with the transcript — shown only when the transcript
            // is (isViewingActiveChat && expanded). At half the home shows
            // "home only" with no stray Back pill. In the other modes it
            // stays the quickfix panel-collapse affordance. (The old
            // `endSessionFooter` / End-session dialog — dead since the
            // Ask→ChatSession rewire — were removed 2026-08-01; the live
            // chat ends via the active-chat pill × dialog above.)
            if isViewingActiveChat {
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
                    AppearancePalette.ink.opacity(0.1)
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
            // ws-librarian-perf Part 1 — debounce the O(nodes) substring scan
            // (was running on every keystroke). Semantic search is already
            // debounced inside kickOffSemanticSearch.
            librarian.scheduleSearchMatches(store: store)
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
        // Active-chat pill × (UNPINNED chats only — pinned ones clear without a
        // dialog). Both non-cancel choices call `startNew()`, so BOTH clear the
        // pill; the only difference is whether the old chat is then tombstoned.
        // So the safe path is "Clear" (it stays in the Chats list), not "Save" —
        // × exists because the user may not want this to be the active chat, not
        // because saving is an opt-in.
        .confirmationDialog(
            "Clear or delete this chat?",
            isPresented: $showChatDisposition,
            titleVisibility: .visible
        ) {
            Button("Clear") {
                // Reset to a fresh empty session; the chat stays in the Chats list.
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
            Text("Clear removes it from here; the chat stays in your Chats list. Delete removes it permanently.")
        }
        .sheet(isPresented: $showingLibrarianPinSheet) {
            PinChatSheet(chatID: router.chat.id).environment(store)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
                .foregroundStyle(AppearancePalette.ink.opacity(0.95))
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
                .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(AppearancePalette.ink.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Librarian home")
            Spacer()
            // #1-followup item 2 — lock + collapse controls relocated here from
            // the top header so the transcript owns the top band. Right side,
            // vertically level with Back.
            lockChevronControls()
        }
        .padding(.horizontal, 20)
        // Item 2 — tunable so T can pull the bottom chrome down into the dead
        // space below Back (default 10 = the prior literal).
        .padding(.bottom, cctBottomInset)
    }

    /// #1-followup — the lock + collapse (chevron) controls, shared by the
    /// home/search header (top-trailing) and the active-chat backPill (bottom-
    /// right) so the two placements never diverge (one source, BUG-10 lesson).
    /// Lock shows only when unlocked; the chevron unlocks when locked, else
    /// drops the panel to peek.
    @ViewBuilder
    private func lockChevronControls() -> some View {
        if !panelModel.isLocked {
            Button {
                panelModel.lockToFull(animated: true)
            } label: {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        if panelModel.isLocked {
            Button {
                panelModel.unlock(animated: true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppearancePalette.ink.opacity(0.10)))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                panelModel.raiseToPeek(animated: true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
    }

    /// #1-followup — scroll-collapsing title opacity: 0 at the transcript top,
    /// ramping to 1 over `cctTitleCollapse` points of upward scroll.
    private var titleCollapseOpacity: Double {
        guard cctTitleCollapse > 0 else { return 1 }
        return min(1, max(0, Double(chatScrollTopOffset) / cctTitleCollapse))
    }

    private func sendIsEnabled(librarian: LibrarianState) -> Bool {
        // STATE 2 — no free-text provider on this device (gated behind a connected model).
        // Reads the CACHED flag (resolved off-render in `refreshActiveModel`), never XPC here.
        if librarian.askUnavailable { return false }
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
                .foregroundStyle(AppearancePalette.ink.opacity(0.55))
            TextField("Search", text: Binding(
                get: { librarian.searchText },
                set: { librarian.searchText = $0 }
            ))
                .focused($isSearchFocused)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(AppearancePalette.ink)
                .tint(AppearancePalette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !librarian.searchText.isEmpty {
                Button {
                    librarian.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppearancePalette.ink.opacity(0.06))
        .clipShape(Capsule())
        // (Reconciler signal moved to a status line beneath the launchpad search
        // field — see `reconcilerStatusLine`. The old `.background` glow here
        // never rendered: this `searchField(...)` is dead code, and even mounted
        // it was occluded behind the field's fill inside the panel material.)
    }

    /// MATCHES (text) and RELATED (semantic) sections rendered when
    /// the search field is non-empty. Resolves node IDs against the
    /// live store at render time so renames/deletes between
    /// keystroke and frame don't surface stale rows.
    @ViewBuilder
    private func searchResultsView(librarian: LibrarianState) -> some View {
        // ws-librarian-perf Part 1 — resolve IDs via an O(1) dictionary built once,
        // not `store.nodes.first(where:)` per row (was O(rows × nodes)).
        let byID: [String: Node] = Dictionary(
            store.nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let matches = librarian.searchMatches
        let imageMatches = librarian.searchImageMatches
        let related = librarian.searchRelated
        // Breathing room below the search field, matching `librarianHome`'s
        // top inset. The home VStack carries `.padding(.vertical, 16)`, so its
        // tiles sit 16pt below the pane top; the results VStack had none, so the
        // first header (MATCHES) crowded the field. Pre-existing asymmetry — not
        // introduced by the reconciler status line (which lives only in the home
        // pane). 12pt here + MATCHES's own `.padding(.top, 4)` restores parity.
        let searchResultsTopInset: CGFloat = 12
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if matches.isEmpty && imageMatches.isEmpty && related.isEmpty && !librarian.searchSemanticInFlight {
                    Text("No matches")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                        .padding(.top, 12)
                }

                if !matches.isEmpty {
                    Text("MATCHES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                        .padding(.top, 4)
                    ForEach(matches) { m in
                        if let node = byID[m.id] {
                            // #3 — two targets: row body focuses in the current
                            // view, the tail Open button pushes Detail.
                            SearchResultRow(
                                onFocus: { focusNode(m.id) },
                                onOpen: { openNode(m.id) }
                            ) {
                                SearchMatchRow(node: node, snippet: m.snippet)
                            }
                        }
                    }
                }

                // IMAGES — literal OCR hits, their own section (self-hides when
                // empty, the Collections/Priority idiom).
                if !imageMatches.isEmpty {
                    Text("IMAGES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                        .padding(.top, !matches.isEmpty ? 8 : 4)
                    ForEach(imageMatches) { m in
                        if let node = byID[m.nodeID] {
                            SearchResultRow(
                                onFocus: { focusNode(m.nodeID) },
                                onOpen: { openNode(m.nodeID) }
                            ) {
                                switch m.source {
                                case .gallery(let entryID):
                                    if let entry = node.items.first(where: { $0.id == entryID }),
                                       let media = entry.mediaItems?.first(where: { $0.id == m.id }) {
                                        SearchImageRow(node: node, entry: entry,
                                                       galleryItem: media, matchedText: m.recognizedText)
                                    }
                                case .hero:
                                    SearchHeroRow(node: node, matchedText: m.recognizedText)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("RELATED")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                    if librarian.searchSemanticInFlight {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(AppearancePalette.ink.opacity(0.45))
                    }
                }
                .padding(.top, (!matches.isEmpty || !imageMatches.isEmpty) ? 8 : 4)

                ForEach(related) { rel in
                    if let node = byID[rel.nodeID] {
                        SearchResultRow(
                            onFocus: { focusNode(rel.nodeID) },
                            onOpen: { openNode(rel.nodeID) }
                        ) {
                            SearchRelatedRow(node: node, snippet: rel.snippet)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, searchResultsTopInset)
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

    /// #3 (search-navigates-by-view) — focus the node in the user's CURRENT
    /// view instead of pushing Detail: fire the shared focus request
    /// (`requestFocus`; Map flies the camera to the orb, List/Card/Grid/
    /// CoverFlow scroll to it) and raise the panel to PEEK so the whole canvas
    /// is visible for the landing — dropToHalf would cover screen-center,
    /// exactly where Map centers the orb. Search never switches view mode. Same
    /// keyboard/panel teardown as `openNode`. The row's tail "Open" button still
    /// calls `openNode` for the direct route to Detail.
    private func focusNode(_ nodeID: String) {
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // §3 (search row must pop out visibly) — if the user is inside a detail
        // view, the focus would fly the camera / scroll the list UNDERNEATH it,
        // where they can't see it. Pop the current surface's detail stack to root
        // first so the focus lands on the visible surface. No-op at depth 0.
        router.requestDismissDetail()
        // Request focus BEFORE the panel resize: `onFocusRequest` defers its
        // scroll one runloop so the raiseToPeek layout lands first, and any
        // surface that remounts across the resize catches the request on
        // `.onAppear`. (See `AppRouter.requestFocus` / `FocusRequestHandler`.)
        router.requestFocus(nodeID)
        panelModel.raiseToPeek(animated: true)
    }

    // MARK: - Chat layout (c14)

    /// Input row at the bottom of the chat pane. Lifted out of
    /// `expandedBody` so the transcript can sit above it as the
    /// The Ask composer = `inputRow` plus its focus glow / bounce / padding.
    /// Extracted so both the active-chat branch and the home/search branch mount
    /// the identical composer (the Librarian's own Ask field — sparkle glyph +
    /// ContextRing + cyan glow — stays the composer; ChatTranscript's built-in
    /// composer is off via `showsComposer: false`).
    @ViewBuilder
    private func askComposer(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // ★ Corpus-aware toggle + active-model indicator — always visible above
            // the Ask field so the user knows which mode the next question runs in AND
            // which model will answer (hybrid-authorship: the system's behaviour is
            // legible, never hidden). Leading-aligned near the feather.
            HStack(spacing: 8) {
                corpusModeToggle(librarian: librarian)
                activeModelLabelView(librarian: librarian)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)

            // STATE 2 — no free-text model on this device: gate Ask (send disabled via
            // `sendIsEnabled`) and say so, routing to Settings. Honest capability boundary,
            // no Retry. (v1-gates § A item 1 — the Ask half of the iOS-18 floor.)
            if librarian.askUnavailable {
                askNoModelNotice
            }

            inputRow(librarian: librarian)
                // Item 2 — the focus glow is driven from the SAME Messages-style
                // RoundedRectangle the field uses (`askCornerRadius`), NOT its own
                // Capsule — so the halo hugs the actual shape at one line (pill) AND
                // when wrapped (rounded rect). No clip so the bloom radiates.
                .background {
                    if sfBloomOn {
                        SolarFlareFieldGlow(
                            shape: RoundedRectangle(cornerRadius: askCornerRadius, style: .continuous),
                            accent: Color(hexString: "1B59C2"),
                            secondary: Color(hexString: "00BFFF"),
                            isVisible: isInputFocused,
                            widthOverride: askGlowWidth,
                            blurOverride: askGlowBlur,
                            opacityOverride: askGlowOpacity
                        )
                    }
                }
                // Safari-style focus bounce — outside `.background` so halo + field
                // scale together. Transform-only; gated on reduceMotion.
                .scaleEffect(isInputFocused ? 1.0 : 0.985)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6),
                    value: isInputFocused
                )
        }
        // 14pt screen margins to match the Search field (width = geo−28 →
        // 14 each side) so the two fields sit at the same width.
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// ★ Private ↔ Corpus mode pill. Default is Private (model's own knowledge,
    /// no retrieval); Corpus turns on notes-grounded answering with [n] citations.
    /// Legibility requirement (T is colourblind): the active state reads by SHAPE +
    /// LABEL + ICON, never colour alone — the two modes use different SF Symbols
    /// (`lock.fill` vs `books.vertical.fill`), different words, and Corpus adds a
    /// visible stroke + heavier fill so the "on" state is unmistakable in grayscale.
    /// Reuses the panel's `AppearancePalette.ink` chrome so it works in both modes.
    @ViewBuilder
    private func corpusModeToggle(librarian: LibrarianState) -> some View {
        let on = librarian.corpusAware
        Button {
            librarian.corpusAware.toggle()   // stored + persisted (didSet → UserDefaults)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "books.vertical.fill" : "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(on ? "Corpus" : "Private")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(AppearancePalette.ink.opacity(on ? 0.9 : 0.55))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(AppearancePalette.ink.opacity(on ? 0.12 : 0.05))
            )
            .overlay(
                // Stroke ONLY in Corpus mode — a grayscale-legible shape cue for "on".
                Capsule().strokeBorder(AppearancePalette.ink.opacity(on ? 0.28 : 0), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Corpus grounding on" : "Private chat")
        .accessibilityHint("Toggles whether answers are grounded in your notes")
    }

    /// ★ Read-only active-model indicator — declares WHICH model will answer the
    /// next Ask (FM friendly name, or the remote endpoint's model id). Quiet by
    /// design (small, low-contrast ink) so it informs without competing with the
    /// mode pill. Reads by TEXT (colourblind-safe); the value comes from
    /// `librarian.activeModelLabel`, refreshed off-render (see `refreshActiveModel`),
    /// never resolved in this body. NOT interactive — this pass declares, it doesn't
    /// pick.
    @ViewBuilder
    private func activeModelLabelView(librarian: LibrarianState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .semibold))
            Text(librarian.activeModelLabel)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)   // long model ids degrade gracefully
        }
        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Answering with \(librarian.activeModelLabel)")
    }

    /// STATE 2 notice for the Ask composer — no free-text provider on this device. Honest
    /// capability boundary: NO Retry, and it deliberately does NOT claim the private model
    /// enables chat (it is wired to the lever only, not Ask). Colorblind-safe (icon SHAPE +
    /// text on a hueless ground, never colour alone). ★ T's final copy (2026-08-15): the verb
    /// is "connect", not "download" — on the floor the only Ask provider is an ollama/LM Studio
    /// endpoint, so offering the download here would promise chat the build cannot deliver.
    private var askNoModelNotice: some View {
        Button { showSettings = true } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                Text("Ask needs a model. This device has none available — you can connect one in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppearancePalette.ink.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityHint("Opens Settings to connect a model for chat")
    }

    /// Trailing mic/send/clear cluster — extracted so it can be a BOTTOM-TRAILING
    /// OVERLAY on the field (not an HStack sibling). As a sibling it had to be
    /// sized to the field height to bottom-align, which ratcheted the height up
    /// and blocked shrink; as an overlay the field height is TextField-driven
    /// (grows AND shrinks) and the cluster just pins to the bottom.
    @ViewBuilder
    private func askTrailingControls(librarian: LibrarianState, kleinGrad: LinearGradient) -> some View {
        let hasText = !librarian.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isHot = dictation.isListening && dictation.activeToken == "ask"
        HStack(spacing: 8) {
            if hasText {
                Button { librarian.inputText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear input")
            }
            if hasText {
                Button {
                    if dictation.isListening && dictation.activeToken == "ask" { dictation.stop() }
                    let text = librarian.inputText
                    librarian.inputText = ""
                    isViewingActiveChat = true
                    panelModel.expandToFull(animated: true)
                    Task { await librarian.groundedSend(query: text, store: store, chat: router.chat) }
                } label: {
                    let enabled = sendIsEnabled(librarian: librarian)
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(enabled ? AnyShapeStyle(kleinGrad)
                                                 : AnyShapeStyle(AppearancePalette.ink.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(!sendIsEnabled(librarian: librarian))
            } else if isHot {
                Button {
                    dictation.toggle(token: "ask", baseline: librarian.inputText,
                                     onUpdate: { librarian.inputText = $0 })
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 22)).foregroundStyle(kleinGrad)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop dictation")
            } else {
                Button {
                    dictation.toggle(token: "ask", baseline: librarian.inputText,
                                     onUpdate: { librarian.inputText = $0 })
                } label: {
                    Image(systemName: "mic.fill").font(.system(size: 22))
                        .foregroundStyle(kleinGrad).opacity(0.8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dictate")
            }
        }
    }

    /// The Ask input row — the panel's persistent bottom composer. The one
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

        // Item 1 — Messages behaviour: a PILL at one line, becoming a rounded
        // rect only as the text wraps. `askCornerRadius` = min(height/2,
        // singleLineHeight/2): at one line height≈52 → radius 26 = capsule
        // (matches the Search field); as it grows the radius stays pinned at 26
        // so it rounds-rects naturally. No line-counting; animates smoothly.
        let askShape = RoundedRectangle(cornerRadius: askCornerRadius, style: .continuous)
        // Item 4 — more separation from the (cream) panel. FILL: dark white@0.04
        // (byte-identical to the prior `ink.opacity(0.04)`); light a stronger dark
        // wash so the field reads. STROKE: the SHARED `restingFieldStroke` (adaptive
        // ink — dark = white / light = #232A2E, α0.22→0.04) — ws-librarian-cleanup
        // unified it with Search's resting stroke (one gradient, two instances).
        let askFill = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.04)
                : UIColor(Color(hexString: "232A2E")).withAlphaComponent(0.075)
        })
        let askStroke = Self.restingFieldStroke

        // Optical alignment — DERIVED from the text's LINE BOX (not container
        // padding, which lands off-centre because a line carries ascender/descender
        // space beyond the glyph). Feather centres on the FIRST line's box, the
        // trailing mic/send on the LAST line's box; at one line those coincide, so
        // both read centred with no special-casing. All values fall out of the font
        // line height, so they stay correct if the font/size changes.
        let askLineHeight = UIFont.systemFont(ofSize: 16, weight: .regular).lineHeight
        // TextField vertical padding chosen so a single line == the parity height
        // (52), removing the minHeight-forced extra space that decoupled the glyphs
        // from the text before.
        let askTextVPad = max(0, (LibrarianSurface.askSingleLineHeight - askLineHeight) / 2)
        // Centre of the top/bottom line box, measured from the field's top/bottom
        // edge (they're symmetric): at one line this is the field centre.
        let askLineCenter = askTextVPad + askLineHeight / 2
        // Feather is a 40pt frame, top-pinned in the row → offset its top so its
        // centre lands on line one's box centre.
        let featherTopInset = max(0, askLineCenter - 20)

        // Item 3 — TOP alignment so the feather (and the growing TextField) pin to
        // the FIRST line as the field wraps, rather than the whole row centring.
        // The trailing mic/send follow; adjusted below if that reads wrong.
        HStack(alignment: .top, spacing: 8) {
            // Ask identity glyph — the feather (AirPadLogo), carrying the Klein
            // BLUE gradient (like the Search magnifier's mango). 40pt frame.
            Image("AirPadLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(kleinGrad)
                .padding(.leading, 12)
                // Optical: centre the 40pt feather on the FIRST line's box
                // (`featherTopInset`, derived from the line height) so it reads
                // centred at one line and stays on line one as the field grows.
                .padding(.top, featherTopInset)

            TextField("Ask", text: Binding(
                get: { librarian.inputText },
                set: { librarian.inputText = $0 }
            ), axis: .vertical)
                .focused($isInputFocused)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(AppearancePalette.ink)
                .tint(klein)
                // Leading 4 (+ the HStack's 8pt spacing) = 12pt from the
                // feather's frame to "Ask", matching the feather's 12pt gap to
                // the field's left edge so the glyph sits equidistant. Trailing
                // stays tight at 8 for the mic/send slot's compactness.
                .padding(.leading, 4)
                // Trailing clearance for the mic/send, which are now a
                // bottom-trailing OVERLAY (not an HStack sibling) — so the text
                // column stops before them at every height.
                .padding(.trailing, 56)
                // Derived so a single line == the 52pt parity height (no minHeight
                // forcing → glyphs stay locked to the text line box).
                .padding(.vertical, askTextVPad)
                .lineLimit(1...4)

        }
        // Height parity with the Search field (morphingField expandedH = 52) so
        // the two composers read as siblings. minHeight (not fixed) so Ask can
        // still grow with multi-line input.
        // minHeight 52 = single-line height (matches the Search field). No fixed
        // height and NO self-referential trailing frame, so the TextField drives
        // the height and it GROWS AND SHRINKS freely on every text change.
        .frame(minHeight: 52)
        // Item 1 — measure the live height to drive the Messages-style corner
        // (`askCornerRadius`). Read-only (feeds the corner, not the height), so no
        // ratchet. Grows/shrinks as the TextField wraps/unwraps (lineLimit 1...4).
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { askFieldHeight = $0 }
        .background(askFill)
        // Item 2 — mic/send/clear as a BOTTOM-TRAILING overlay (not an HStack
        // sibling). Optical: constrain the cluster to the LINE-BOX height and pin
        // it `askTextVPad` from the bottom, so the glyph centres on the LAST line's
        // box (derived — no magic number). At one line last == first, so it reads
        // centred; as the field grows it rides the last line. (Feather is top-
        // pinned on line one in the HStack above.)
        .overlay(alignment: .bottomTrailing) {
            askTrailingControls(librarian: librarian, kleinGrad: kleinGrad)
                .frame(height: askLineHeight)
                .padding(.trailing, 10)
                .padding(.bottom, askTextVPad)
        }
        // Whole-capsule tap target — single-tap focuses Ask from
        // anywhere on the pill (icons, the padded gap to the right of
        // the mode glyph, the trailing area before mic/send), not
        // just the TextField text region. The leading mode-glyph
        // Button and trailing send/mic Button consume their own taps
        // (`.buttonStyle(.plain)` does not propagate), so they still
        // fire correctly; this gesture only catches the "empty"
        // capsule regions.
        .contentShape(askShape)
        .onTapGesture {
            isInputFocused = true
        }
        // Item 1 — `askShape` = the Messages-style RoundedRectangle whose radius
        // is `askCornerRadius` (capsule at one line → rounded rect as it grows).
        // clip + stroke both use it; the focus glow (askComposer) uses the SAME
        // shape so they can't disagree (item 2). Stroke is the adaptive ink
        // gradient (dark = white lit-top-edge byte-identical; light = dark ink).
        .clipShape(askShape)
        .overlay(
            askShape.strokeBorder(askStroke, lineWidth: 1)
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

    /// Ask-mode Librarian home — the capability-tile launchpad (compressed
    /// to a single row) plus, when a conversation exists, the active-chat
    /// pill that jumps back into it. This is the landing surface when
    /// `isViewingActiveChat` is false; Back returns here from the
    /// transcript.
    @ViewBuilder
    private func librarianHome(librarian: LibrarianState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Reconciler status — a quiet line BENEATH the search field (which
                // sits above this home), above the tiles. Self-hiding on
                // `isReconcilingSubstrate`; inserting/removing pushes the tiles +
                // pill down and back. No reserved space when absent.
                if store.isReconcilingSubstrate {
                    reconcilerStatusLine()
                        .transition(.asymmetric(
                            insertion: .push(from: .top).combined(with: .opacity),
                            removal: .opacity))
                }

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
            .animation(.easeInOut(duration: 0.35), value: store.isReconcilingSubstrate)
        }
        .floatingPanelScrollTracking(proxy: proxy)
    }

    /// ws-substrate — the reconciler's ambient signal, replacing the invisible
    /// glow. A quiet status line: an animated SF Symbol (built-in
    /// `.variableColor`, NOT a shimmer — shimmer is reserved for THE LEVER) plus
    /// STATIC text. Says "search works, results are still filling in" — never
    /// "wait". Signal = TEXT + MOTION (colorblind-safe; no hue carries meaning).
    /// Baked defaults, no tuner.
    private func reconcilerStatusLine() -> some View {
        HStack(spacing: 7) {
            // ellipsis — NOT sparkles/wand/magic iconography. App-wide ban:
            // sparkles has become the industry's "AI" shorthand and reads as an
            // empty promise; the Librarian is patient legible work, not performed
            // wonder. Dots fill in sequence via the built-in variableColor
            // animation — punctuation that reads as "ongoing" and nothing else.
            // NOT a shimmer (shimmer is reserved for THE LEVER).
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                .symbolEffect(.variableColor.iterative, options: .repeating)
            // No trailing "…" — the glyph IS the ellipsis; the copy would say it twice.
            Text("Still adding older items")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Active-chat pill on the Ask home. Body tap resumes the live
    /// `router.chat`; trailing × opens the keep/discard dialog. Title
    /// tracks `displayTitle` (FM title once it lands, truncation
    /// fallback before).
    @ViewBuilder
    private func activeChatPill() -> some View {
        // ws-librarian — pinned-chat pill height. Was vertical-10 (T: "very
        // skinny, almost easy to ignore"); bumped so it holds its own against the
        // launchpad tiles above. Baked default, no tuner — height is the only
        // thing out of step; the rest of the visual vocabulary is unchanged.
        let verticalPadding: CGFloat = 16
        let isPinned = store.nodePinned(forChatID: router.chat.id) != nil
        return HStack(spacing: 10) {
            Button {
                // Resume the chat: raise to full so the transcript shows
                // (transcript ⟺ isViewingActiveChat && expanded), never a
                // blank half. BUG 5 (A) — flip the mount-gate one runloop tick
                // LATER so ChatTranscript mounts after the spring starts, not
                // during it. (Instrumentation proved the mount is ~4ms and not
                // the cause; the crawl was the spring DURATION — fixed in
                // LibrarianPanelBehavior. Kept because it's correct + harmless.)
                panelModel.expandToFull(animated: true)
                Task { @MainActor in isViewingActiveChat = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hexString: "00BFFF"))
                    Text(router.chat.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppearancePalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume chat: \(router.chat.displayTitle)")

            // ws-chat-lane — pin the active chat to a node. The THIRD entry point
            // (full chat toolbar + Chats-list context menu are the others): SAME
            // `PinChatSheet`, SAME `pin`/`pin.fill` glyph, pinned state from the
            // SAME derived source (`nodePinned`) — no third path, no local flag.
            // Shape not hue (colorblind-safe).
            Button {
                router.chat.flush()   // persist so the chat resolves in the node's entry
                showingLibrarianPinSheet = true
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 16))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "Change pinned node" : "Pin chat to a node")

            Button {
                if isPinned {
                    // A pinned chat is already persisted AND has a home on a node,
                    // so "clear or delete?" would be the app forgetting what it was
                    // just told. Clear the pill immediately — Delete stays available
                    // from the Chats list, where the pinned-chat warning lives. This
                    // also removes the pill's unguarded destructive path.
                    router.chat.startNew()
                } else {
                    showChatDisposition = true
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "Clear chat from here" : "Clear or delete chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, verticalPadding)
        .background(AppearancePalette.ink.opacity(0.06))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func retrievalList(nodeIDs: [String]) -> some View {
        let nodes = nodeIDs.compactMap { id in
            store.nodes.first { $0.id == id }
        }

        if nodes.isEmpty {
            Text("No matches.")
                .font(.system(size: 15))
                .foregroundStyle(AppearancePalette.ink.opacity(0.55))
        } else {
            LazyVStack(spacing: 10) {
                ForEach(nodes) { node in
                    Button {
                        router.pendingNodeNavigationID = node.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppearancePalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !node.summary.isEmpty {
                                Text(node.summary)
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(2)
                            }

                            Text(node.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(AppearancePalette.ink.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Landing tiles that occupy the pocket (no session, empty search)
    /// in place of the retired "Try Asking" suggestions list. `singleRow`
    /// lays them out as one row of compact cards (the Ask home, which
    /// needs vertical room beneath for the active-chat pill). ★ The default
    /// 2×2 grid branch has NO current caller — only `librarianHome` renders
    /// this, with `singleRow: true`. ★ ws-librarian-cleanup: only the Chats
    /// tile survives; the other three were inert stubs (see `capabilityTiles`).
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

    /// The landing tile(s), shared by the grid + single-row layouts.
    /// `compact` shrinks the card for the single-row (Ask home) case.
    @ViewBuilder
    private func capabilityTiles(compact: Bool) -> some View {
        // ws-librarian-cleanup (2026-08-19): Insights + Inbox REMOVED (inert stubs — empty `// TODO`
        // action closures, tappable but no-ops). Chats is the live tile. Capsule is RESTORED (T's
        // call) as an explicitly DISCLOSED placeholder via `comingSoonTile` — non-interactive (no
        // Button), a dashed outline, and a literal "Coming soon" caption, so it reads as deliberately
        // unavailable and SAYS why. The prior tile's sin was being dimmed and SILENT about it.
        // Insights/Inbox destinations (corpus reflection, Inbox/SB134) remain in their workstreams,
        // still unwired.
        capabilityTile(
            label: "Chats",
            systemImage: "bubble.left.and.bubble.right",
            compact: compact
        ) {
            // Drop to .half first so a full-detent Librarian doesn't
            // present the sheet from behind itself — mirrors the
            // `openNode` handoff pattern above.
            panelModel.dropToHalf(animated: true)
            router.showChatsList = true
        }
        comingSoonTile(label: "Capsule", systemImage: "shippingbox", compact: compact)
    }

    /// One tile in `capabilityTileGrid`. Icon-led card with a small
    /// label beneath. Solar Flare rim-light treatment lands in a
    /// later art-direction pass — this is the placeholder card style.
    @ViewBuilder
    private func capabilityTile(
        label: String,
        systemImage: String,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let card = VStack(spacing: compact ? 6 : 10) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 18 : 22, weight: .regular))
                .foregroundStyle(AppearancePalette.ink.opacity(0.85))
            Text(label)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 12 : 18)
        .padding(.horizontal, compact ? 8 : 16)
        .background(AppearancePalette.ink.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 14))

        Button(action: action) { card }
            .buttonStyle(.plain)
    }

    /// A deliberately-UNAVAILABLE placeholder tile (T's call for Capsule). Distinct from
    /// `capabilityTile` in three colorblind-safe ways — no colour signalling: (1) NOT wrapped in a
    /// Button, so it's untappable; (2) a DASHED outline instead of a solid fill (shape, not hue);
    /// (3) a literal "Coming soon" caption — it SAYS why it's inert, rather than being dimmed and
    /// silent (the prior tile's failure). Same `.frame(maxWidth: .infinity)` as `capabilityTile`,
    /// so in the single row the two tiles split the width evenly.
    @ViewBuilder
    private func comingSoonTile(label: String, systemImage: String, compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 6) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 18 : 22, weight: .regular))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            Text(label)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Coming soon")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 9 : 14)
        .padding(.horizontal, compact ? 8 : 16)
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 14)
                .strokeBorder(
                    AppearancePalette.ink.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        // No Button wrapper — deliberately non-interactive.
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
                .foregroundStyle(isSelected ? .black : AppearancePalette.ink.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? Color.white : AppearancePalette.ink.opacity(0.08))
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
/// #3 (search-navigates-by-view) — two-target wrapper for a search result row.
/// The body is a large tap target that **focuses the node in the user's current
/// view** (`onFocus` → `router.requestFocus`); the tail "Open" button
/// **pushes the Detail view** (`onOpen` → `openNode`). Search never switches
/// view mode — see `ws-instant-search.md` § NAVIGATION BEHAVIOUR ON TAP. Used
/// by both MATCHES and RELATED rows so the two targets stay consistent.
private struct SearchResultRow<Label: View>: View {
    let onFocus: () -> Void
    let onOpen: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onFocus) { label() }
                .buttonStyle(.plain)
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open in detail view")
        }
    }
}

private struct SearchMatchRow: View {
    let node: Node
    /// Entry-BODY hit → a pull quote around the match. nil for title/summary/tag
    /// hits, where the row falls back to the node summary.
    var snippet: String? = nil

    private var displaySnippet: String {
        if let snippet, !snippet.isEmpty { return snippet }
        if let s = node.substrateSummary, !s.isEmpty { return s }
        return node.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.title.isEmpty ? "Untitled" : node.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                .lineLimit(1)
            if !displaySnippet.isEmpty {
                Text(displaySnippet)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// IMAGE result row for a directly-picked HERO hit — the hero thumbnail, resolved
/// via the store's `coverImageURL` (the SAME source the hero banner uses), with the
/// matched OCR text as caption. Same shape as `SearchImageRow`; a hero just has no
/// `GalleryItem`, so the thumbnail loads from `coverImageRelativePath`.
private struct SearchHeroRow: View {
    let node: Node
    let matchedText: String
    @Environment(CorpusStore.self) private var store
    @State private var image: UIImage? = nil

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Rectangle().fill(AppearancePalette.ink.opacity(0.08))
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(AppearancePalette.ink.opacity(0.3))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title.isEmpty ? "Untitled" : node.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                    .lineLimit(1)
                Text(matchedText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .task(id: node.coverImageRelativePath) {
            guard let url = await store.coverImageURL(for: node) else { return }
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)
            }.value
            image = decoded
        }
    }
}

/// IMAGE result row — the gallery thumbnail (reusing `GalleryItemTile`'s own
/// resolve+decode; no second thumbnail path) with the matched OCR text as a
/// caption beneath. The picture is a better preview than a text snippet.
/// ★ TAP RULING (flagged for T): opens the NODE DETAIL, same as every other row.
/// Alternatives — the gallery entry, or the lightbox at this image — are
/// defensible; this is the simplest.
private struct SearchImageRow: View {
    let node: Node
    let entry: NodeItem
    let galleryItem: GalleryItem
    let matchedText: String

    var body: some View {
        HStack(spacing: 10) {
            GalleryItemTile(galleryItem: galleryItem, nodeID: node.id, parentItem: entry)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title.isEmpty ? "Untitled" : node.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                    .lineLimit(1)
                Text(matchedText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                .lineLimit(1)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// Re-applies a peekProgress-derived opacity over BUILD-ONCE content. Parent builds the
/// content once and stores it; only this wrapper re-evaluates per frame (it observes the
/// isolated MorphProgressModel) and all it does is change `.opacity()` — a cheap
/// composite, NOT a rebuild. This keeps the SolarFlareMaterial blur + the chrome out of
/// the per-frame path.
private struct PeekFadeLayer<Content: View>: View {
    // @Observable: reads `progress.peekProgress` in body, so ONLY this leaf
    // re-evaluates per frame — the surface body holding the model does not.
    let progress: MorphProgressModel
    let content: Content
    var body: some View {
        content.opacity(max(0, (progress.peekProgress - 0.5) / 0.5))
    }
}

/// Hands the live per-frame peekProgress to a builder in an ISOLATED subtree. Only this
/// view re-evaluates per frame; the parent body does not (it doesn't observe the morph
/// model). Used by the morphing field, which genuinely needs the continuous value.
private struct PeekProgressReader<V: View>: View {
    // @Observable: only this isolated subtree re-evaluates per frame.
    let progress: MorphProgressModel
    @ViewBuilder let build: (CGFloat) -> V
    var body: some View { build(progress.peekProgress) }
}

