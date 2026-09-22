import SwiftUI

// MARK: - Brief AG3 — first-run callouts (custom, not TipKit)
//
// One reusable card: glass (`.dashboardPaneSurface()`), display-face headline, text-face
// body, no new hex. Overlay, not modal — the surface stays visible, dimmed ≤ 12 %. ANY tap
// (card or outside) dismisses with a 200 ms fade; there is no ×. Optional soft rings around
// 1–2 named controls (shape, not colour) and up to 3 tap-to-send actions. Each key shows once,
// persisted at `com.airpad.callouts.<key>`; Settings → "Reset first-time tips" clears them.
//
// Hosts (they own WHEN — settle, beat, sequencing):
//   - `CanvasChrome` — `view.buttons` (every view) then `map.intro` (Map only).
//   - `LibrarianSurface` — `librarian.intro` / `librarian.sample` on first raise per room.

enum FirstRunCalloutKey: String, CaseIterable, Identifiable {
    case viewButtons     = "view.buttons"
    case mapIntro        = "map.intro"
    case librarianIntro  = "librarian.intro"
    case librarianSample = "librarian.sample"
    case librarianMode   = "librarian.mode"   // Brief AH3 — first tap of the mode chip
    case librarianModel  = "librarian.model"  // Brief AH3 — first tap of the model chip

    var id: String { rawValue }

    var defaultsKey: String { "com.airpad.callouts.\(rawValue)" }

    var hasShown: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    func markShown() { UserDefaults.standard.set(true, forKey: defaultsKey) }

    /// Settings → "Reset first-time tips".
    static func resetAll() {
        for key in allCases { UserDefaults.standard.removeObject(forKey: key.defaultsKey) }
    }

    /// Final copy (Brief AG4 — ruled; edit only in the brief).
    var content: FirstRunCalloutContent {
        switch self {
        case .viewButtons:
            return FirstRunCalloutContent(
                headline: "Two buttons, everything.",
                body: ["**View** switches between Map, List and Cards.",
                       "**Capture** starts a new entry — saved the moment it opens."],
                targets: [FirstRunCalloutTargetID.viewButton, FirstRunCalloutTargetID.captureButton]
            )
        case .mapIntro:
            return FirstRunCalloutContent(
                headline: "Welcome to Map View",
                body: ["A layout of everything you've saved, arranged by collection, tag, meaning and backlink — a fingerprint of how you think.",
                       "Regions form as you add to them. Pinch and pan like any map. Tap an entry for a quick look, then tap the quick look to open it."]
            )
        case .librarianIntro:
            return FirstRunCalloutContent(
                headline: "Librarian",
                body: ["**Library** reads your entries and cites them. **General** answers from the model — and the web, once you've added a search key."]
            )
        case .librarianSample:
            return FirstRunCalloutContent(
                headline: "Ask this library anything.",
                body: [],
                actions: ["What do I have on learning French?",
                          "What can you tell me about my entry called \"Silent Hill 2's fog\"?",
                          "How did coffee spread out of Ethiopia?"]
            )
        case .librarianMode:
            // A terse coach-mark — no headline, one line (Brief AH3).
            return FirstRunCalloutContent(
                headline: nil,
                body: ["Switch anytime. Library cites your entries; General doesn't read them."],
                targets: [FirstRunCalloutTargetID.librarianModeChip]
            )
        case .librarianModel:
            return FirstRunCalloutContent(
                headline: nil,
                body: ["Choose who answers — on your phone, or on your Mac with the Host."],
                targets: [FirstRunCalloutTargetID.librarianModelChip]
            )
        }
    }
}

struct FirstRunCalloutContent {
    /// nil for terse coach-marks (`librarian.mode` / `.model`) — body-only, one line.
    var headline: String?
    /// Paragraphs. Markdown `**bold**` is honoured (the control names in `view.buttons`).
    var body: [String]
    var targets: [String] = []
    var actions: [String] = []
}

/// Named controls a callout can ring. The control tags itself with
/// `.firstRunCalloutTarget(_:)`; the host's overlay reads the anchors.
enum FirstRunCalloutTargetID {
    static let viewButton    = "view"
    static let captureButton = "capture"
    static let librarianModeChip  = "librarian.mode.chip"   // Brief AH3
    static let librarianModelChip = "librarian.model.chip"  // Brief AH3
}

struct FirstRunCalloutTargetsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Tags a control so a callout can draw its ring around it.
    func firstRunCalloutTarget(_ id: String) -> some View {
        anchorPreference(key: FirstRunCalloutTargetsKey.self, value: .bounds) { [id: $0] }
    }
}

// MARK: - Timing tokens

enum FirstRunCalloutTiming {
    /// The beat after the surface settles (and between two callouts) before a card appears.
    static let beat: Duration = .milliseconds(400)
    /// Dismiss fade.
    static let dismissSeconds: Double = 0.2
}

// MARK: - Overlay

/// Full-bleed overlay: dim + rings + card. Place it at the TOP of the host's ZStack and
/// feed it the host's target anchors (`overlayPreferenceValue(FirstRunCalloutTargetsKey.self)`).
/// `onDismiss` fires AFTER the 200 ms fade; the host clears its state and marks the key shown.
struct FirstRunCalloutOverlay: View {
    let key: FirstRunCalloutKey
    var targetAnchors: [String: Anchor<CGRect>] = [:]
    /// Tap-to-send. Called on tap, before the dismiss fade.
    var onAction: (String) -> Void = { _ in }
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var dismissing = false
    /// Brief AH4 — `librarian.mode`'s ring pulses ONCE (1.0→1.06→1.0, ~600 ms) then
    /// stops. No looping anywhere. Other callouts keep a static ring.
    @State private var ringPulse: CGFloat = 1.0
    private var pulsesRing: Bool { key == .librarianMode }

    /// Dim ≤ 12 % (Brief AG3). Black at 0.10 — not a new colour token, an opacity scrim.
    private static let dimOpacity: Double = 0.10

    private var content: FirstRunCalloutContent { key.content }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(Self.dimOpacity)
                    .ignoresSafeArea()

                ForEach(content.targets, id: \.self) { id in
                    if let anchor = targetAnchors[id] {
                        ring(around: geo[anchor])
                    }
                }

                card
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 24)
                    .offset(y: (shown || reduceMotion) ? 0 : 8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(shown && !dismissing ? 1 : 0)
        .contentShape(Rectangle())
        // ANY tap — card or outside — dismisses. Action buttons inside the card win their own tap.
        .onTapGesture { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
        .onAppear {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) { shown = true }
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { shown = true }
                // AH4 — one-shot ring pulse (up then back), never a loop.
                if pulsesRing {
                    withAnimation(.easeInOut(duration: 0.3)) { ringPulse = 1.06 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeInOut(duration: 0.3)) { ringPulse = 1.0 }
                    }
                }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            // One readable block for VoiceOver; double-tap dismisses (the sighted "tap anywhere").
            VStack(alignment: .leading, spacing: 10) {
                if let headline = content.headline {
                    Text(headline)
                        .font(.custom("Fraunces72pt-Bold", size: 22, relativeTo: .title3))
                        .foregroundStyle(AppearancePalette.ink)
                }
                ForEach(Array(content.body.enumerated()), id: \.offset) { _, paragraph in
                    Text((try? AttributedString(markdown: paragraph)) ?? AttributedString(paragraph))
                        .font(.custom("SourceSerif4-Regular", size: 17, relativeTo: .body))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityAction { dismiss() }
            .accessibilityHint("Double-tap to dismiss.")

            if !content.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(content.actions.prefix(3), id: \.self) { question in
                        Button {
                            onAction(question)
                            dismiss()
                        } label: {
                            Text(question)
                                .font(.custom("SourceSerif4-Regular", size: 16, relativeTo: .callout))
                                .foregroundStyle(AppearancePalette.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(AppearancePalette.ink.opacity(0.07))
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Asks the Librarian.")
                    }
                }
            }
        }
        .padding(20)
        .dashboardPaneSurface()
    }

    /// Soft ring — a SHAPE cue (≥ 2 pt stroke, appearance-aware ink), never a colour cue.
    private func ring(around rect: CGRect) -> some View {
        let inset: CGFloat = 6
        let r = rect.insetBy(dx: -inset, dy: -inset)
        return RoundedRectangle(cornerRadius: min(r.width, r.height) / 2, style: .continuous)
            .strokeBorder(AppearancePalette.ink.opacity(0.8), lineWidth: 2.5)
            .frame(width: r.width, height: r.height)
            .scaleEffect(ringPulse)
            .position(x: r.midX, y: r.midY)
            .accessibilityHidden(true)
    }

    private func dismiss() {
        guard !dismissing else { return }
        withAnimation(.easeOut(duration: FirstRunCalloutTiming.dismissSeconds)) { dismissing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + FirstRunCalloutTiming.dismissSeconds) {
            onDismiss()
        }
    }
}

#if DEBUG
/// Brief AG verify — a headless screenshot harness. `-CalloutGallery <key>` mounts ONE callout
/// over a neutral ground, with faithful View + Capture button stubs bottom-right so the
/// `view.buttons` rings land where they do on the real canvas. Data-independent (no store), so
/// each of the four callouts can be captured in BOTH appearances (flip via `simctl ui appearance`)
/// without driving the live host gating (surface-settle / sheet-raise) that a bare launch can't.
/// NOT reachable in production — launch-arg only.
struct CalloutGalleryView: View {
    /// The `FirstRunCalloutKey` rawValue, e.g. "view.buttons".
    let key: String
    @State private var dismissed = false

    private var calloutKey: FirstRunCalloutKey? { FirstRunCalloutKey(rawValue: key) }

    var body: some View {
        ZStack {
            AppearancePalette.bgBase.ignoresSafeArea()

            // Brief AH — `-CalloutGallery chip.modes` shows the mode chip in BOTH states
            // (General globe / Library books) with no overlay, for the rename screenshot.
            if key == "chip.modes" {
                VStack(spacing: 18) {
                    galleryModeChip(on: false)   // General
                    galleryModeChip(on: true)    // Library
                }
            }

            // Composer-like pill row (bottom-left) + View/Capture stack (bottom-right), so
            // every callout's rings land on a faithful anchor. Hidden in the chip.modes shot.
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    HStack(spacing: 8) {
                        galleryModeChip(on: false)
                            .firstRunCalloutTarget(FirstRunCalloutTargetID.librarianModeChip)
                        galleryModelChip()
                            .firstRunCalloutTarget(FirstRunCalloutTargetID.librarianModelChip)
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        calloutButtonStub(systemName: "map")
                            .firstRunCalloutTarget(FirstRunCalloutTargetID.viewButton)
                        calloutButtonStub(systemName: "plus")
                            .firstRunCalloutTarget(FirstRunCalloutTargetID.captureButton)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 44)
            }
            .opacity(key == "chip.modes" ? 0 : 1)
        }
        .overlayPreferenceValue(FirstRunCalloutTargetsKey.self) { anchors in
            if let k = calloutKey, !dismissed {
                FirstRunCalloutOverlay(key: k, targetAnchors: anchors) { dismissed = true }
                    .id(k)
            }
        }
    }

    private func calloutButtonStub(systemName: String) -> some View {
        Circle()
            .fill(AppearancePalette.ink.opacity(0.10))
            .frame(width: 56, height: 56)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
            )
    }

    /// Matches `LibrarianSurface.corpusModeToggle` (Brief AH1 icon + labels) so the
    /// screenshot previews the real chip. General = globe; Library = books + stroke.
    private func galleryModeChip(on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: on ? "books.vertical.fill" : "globe")
                .font(.system(size: 11, weight: .semibold))
            Text(on ? "Library" : "General")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(AppearancePalette.ink.opacity(on ? 0.9 : 0.55))
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(AppearancePalette.ink.opacity(on ? 0.12 : 0.05)))
        .overlay(Capsule().strokeBorder(AppearancePalette.ink.opacity(on ? 0.28 : 0), lineWidth: 1))
    }

    /// Matches `LibrarianSurface.activeModelLabelView` — the read-only model indicator.
    private func galleryModelChip() -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu").font(.system(size: 9, weight: .semibold))
            Text("qwen3:8b").font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
    }
}
#endif
