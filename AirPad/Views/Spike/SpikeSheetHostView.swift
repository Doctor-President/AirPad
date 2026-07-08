//  SpikeSheetHostView.swift
//  ⚠️ THROWAWAY SPIKE — native `.presentationDetents` sheet in ISOLATION from
//  the FloatingPanel. Not wired into the Librarian / Ask lane / LibrarianSurface.
//  It is the app root on the `spike/native-sheet` branch (see AirPadApp.swift).
//
//  REVISION 2 — use the iOS 26 NATIVE floating-glass technique instead of the
//  drawn-capsule workaround (old Path B).
//
//  KEY FINDING (research, confirmed against Apple / .NET-iOS-26.4 bindings):
//  On iOS 26 a partial-height sheet FLOATS by default — Liquid Glass background,
//  device-concentric rounded corners, edges lifted off all four sides — and only
//  becomes edge-attached + opaque at `.large`. The old spike looked malformed
//  because `.presentationBackground { … }` OVERRODE that native glass with our
//  drawn capsule + clear surround, leaving a seam. The fix is to DELETE the fake
//  and let the system do it: partial detent(s) + NO presentationBackground.
//
//  So the recipe for the floating capsule is almost entirely subtractive.
//  `UIGlassEffect` / `UISheetPresentationController.backgroundEffect` (26.1) are
//  OPTIONAL customization hooks, exercised below behind `kApplyExplicitGlass`.
//
//  DELETE-FRIENDLY: delete this file and restore `ContentView()` in AirPadApp.swift.
//  Touches no production files beyond the root-swap launch hook.

import SwiftUI
import UIKit

/// Flip to `true` to TEST the EXPLICIT iOS 26.1 `backgroundEffect` API (sets the
/// sheet glass by hand) instead of relying on the automatic native glass.
/// Default `false` = pure native float, the technique we actually want.
private let kApplyExplicitGlass = false

// MARK: - Launch host

/// App root on the spike branch. A dummy full-screen "canvas" that always
/// presents the native sheet. The sheet can't be dismissed
/// (`interactiveDismissDisabled`), so the rig is always on screen.
struct SpikeSheetHostView: View {
    @State private var showSheet = true
    /// Live settled detent — drives the peek/expanded content swap. Updated on
    /// settle only (NOT per drag frame), which is exactly what the heavy content
    /// should key off of.
    @State private var detent: PresentationDetent = SpikeMetrics.peekDetent
    /// Passthrough proof: tapping the exposed canvas at peek increments this.
    @State private var canvasTaps = 0

    var body: some View {
        SpikeCanvas(taps: $canvasTaps)
            .sheet(isPresented: $showSheet) {
                SpikeSheetContent(detent: detent)
                    // Reach-in for verification logging + the OPTIONAL explicit
                    // glass API. Invisible; does not affect the native glass.
                    .background(SheetGlassConfigurator(applyExplicitGlass: kApplyExplicitGlass))
                    // At least one PARTIAL detent → the system floats the sheet
                    // (glass + rounded corners + margins). `.large` attaches it.
                    .presentationDetents(
                        [SpikeMetrics.peekDetent, .fraction(0.5), .large],
                        selection: $detent
                    )
                    // Canvas stays touch-live while at (or below) peek.
                    .presentationBackgroundInteraction(.enabled(upThrough: SpikeMetrics.peekDetent))
                    // Discoverable drag affordance for the detent-morph test.
                    .presentationDragIndicator(.visible)
                    // Throwaway rig — never let it be swiped away.
                    .interactiveDismissDisabled(true)
                    // NOTE: intentionally NO `.presentationBackground` and NO
                    // `.presentationCornerRadius` — overriding either defeats the
                    // iOS 26 automatic floating-glass capsule. This absence IS
                    // the fix.
            }
    }
}

// MARK: - Metrics

enum SpikeMetrics {
    /// Peek band height. `.height(96)` per the brief. (A partial detent, so it
    /// should float; `.fraction(0.5)` is also in the set as a guaranteed-partial
    /// fallback if 96pt turns out to be below a system float threshold.)
    static let peekHeight: CGFloat = 96
    static var peekDetent: PresentationDetent { .height(peekHeight) }
}

// MARK: - Dummy canvas (stand-in for the real canvas)

/// Full-screen colored background behind the sheet. The tap counter proves the
/// canvas is live at peek (background interaction) and inert at half/full.
private struct SpikeCanvas: View {
    @Binding var taps: Int
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hexString: "1B59C2"), Color(hexString: "3A0A5E")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("SPIKE CANVAS")
                    .font(.system(size: 22, weight: .bold))
                Text("canvas taps: \(taps)")
                    .font(.system(size: 34, weight: .heavy).monospacedDigit())
                Text("Tap the canvas at PEEK → should increment.\nAt half/full it must NOT.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.bottom, 220)   // keep the label clear of the peek band
        }
        // Whole canvas is one tap target so passthrough is easy to hit.
        .contentShape(Rectangle())
        .onTapGesture { taps += 1 }
    }
}

// MARK: - Sheet content (dummy, deliberately heavy at half/full)

/// Peek → a single `Text("peek")`. Half/full → a NON-lazy VStack of ~40
/// material rows so the content is genuinely heavy — the perf test is that a
/// native sheet lays this out ONCE and translates the frame during the drag,
/// rather than re-evaluating per morph frame. Root stays background-CLEAR so the
/// native Liquid Glass shows through.
private struct SpikeSheetContent: View {
    let detent: PresentationDetent

    var body: some View {
        // Per-eval log — confirms the content body does NOT re-run every morph
        // frame (it should only re-run on a settled detent change).
        let _ = SpikeRenderLog.contentBody(detent: detent)

        Group {
            if detent == SpikeMetrics.peekDetent {
                Text("peek")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // NON-lazy on purpose: force all 40 rows to lay out at once
                    // so the content is heavy. A LazyVStack would only build
                    // visible rows and hide the very cost we're measuring.
                    VStack(spacing: 12) {
                        ForEach(0..<40, id: \.self) { i in
                            SpikeRow(index: i)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 44)
                    .padding(.bottom, 60)
                }
            }
        }
    }
}

/// One deliberately-heavy-ish row: material fill + text.
private struct SpikeRow: View {
    let index: Int
    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholder row \(index)")
                    .font(.system(size: 15, weight: .medium))
                Text("Some secondary text so the row has real height and weight.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - iOS 26 reach-in (verification + OPTIONAL explicit glass)

/// Bridges into the live `UISheetPresentationController`. The native floating
/// glass is AUTOMATIC (see file header) so this is NOT required for the effect —
/// it exists to (a) LOG the real sheet state for verification and (b) let us
/// exercise the EXPLICIT `backgroundEffect` API (iOS 26.1) when
/// `applyExplicitGlass` is on. Renders nothing.
private struct SheetGlassConfigurator: UIViewControllerRepresentable {
    var applyExplicitGlass: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        let apply = applyExplicitGlass
        // Async so presentation has finished wiring the sheet controller.
        DispatchQueue.main.async {
            guard let sheet = Self.enclosingSheet(of: vc) else {
                print("🧪 SheetGlassConfigurator: no sheetPresentationController yet")
                return
            }
            let detentID = sheet.selectedDetentIdentifier?.rawValue ?? "nil"
            if #available(iOS 26.1, *) {
                print("🧪 sheet detent=\(detentID) backgroundEffect(before)=\(String(describing: sheet.backgroundEffect))")
                if apply {
                    // The EXPLICIT recipe, if we ever want to force it:
                    sheet.backgroundEffect = UIGlassEffect(style: .regular)
                    print("🧪 applied explicit UIGlassEffect(style: .regular)")
                }
            } else {
                print("🧪 sheet detent=\(detentID) (backgroundEffect needs iOS 26.1)")
            }
        }
    }

    /// Walk up from this child VC to the presented VC that owns the sheet.
    private static func enclosingSheet(of vc: UIViewController) -> UISheetPresentationController? {
        var current: UIViewController? = vc
        while let c = current {
            if let sheet = c.sheetPresentationController { return sheet }
            current = c.parent
        }
        return nil
    }
}

// MARK: - Perf instrumentation

/// Body-eval instrumentation for the perf question. Prints how often the heavy
/// content body re-evaluates — it should stay flat while dragging between
/// detents (native translates the frame; it does not re-lay-out the content).
@MainActor
enum SpikeRenderLog {
    static var contentEvals = 0
    static func contentBody(detent: PresentationDetent) {
        contentEvals += 1
        let label = detent == SpikeMetrics.peekDetent ? "peek" : "expanded"
        print("🧪 SpikeSheetContent body eval #\(contentEvals) (\(label))")
    }
}
