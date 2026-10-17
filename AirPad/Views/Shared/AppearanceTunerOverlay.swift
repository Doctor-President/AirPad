#if DEBUG || TESTFLIGHT
import SwiftUI
import UIKit

/// live-22 (2) — the on-device appearance tuner's UI (TestFlight only; the model and the gate are in
/// `AppearanceTuning`). A small handle floats over EVERY view — Map, Card, vertical cards, List, Recents, entry detail,
/// sheets, the open Librarian — because it lives in its own window above the app's. Tap it for a compact sheet (drag
/// its header to move it up or down, so it never has to cover what's being judged); drag the handle to move it;
/// long-press it to hide it until the next launch. Every change applies live.

// MARK: - The window

/// Mounted once, from `ContentView`: finds the app's window scene and opens the tuner's window on it.
struct AppearanceTunerInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            isHidden = true
            if let scene = window?.windowScene { AppearanceTunerWindow.install(on: scene) }
        }
    }
}

/// A window above the app's that only takes touches on the tuner itself (the handle or the open sheet); every other
/// touch falls through to the app underneath.
final class AppearanceTunerWindow: UIWindow {
    private static var installed: AppearanceTunerWindow?
    /// Where the tuner is on screen (window coordinates), reported by the SwiftUI view.
    var touchRects: [CGRect] = []

    static func install(on scene: UIWindowScene) {
        guard installed == nil else { return }
        let w = AppearanceTunerWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        w.backgroundColor = .clear
        w.overrideUserInterfaceStyle = AppearanceOverride.current().uiStyle   // later changes: AppearanceApplier
        let host = TunerHostingController(rootView: AppearanceTunerRoot(window: w))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        installed = w
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        touchRects.contains { $0.contains(point) }
    }
}

/// Defers the status bar to the app's own window, so the tuner's window never changes it.
private final class TunerHostingController: UIHostingController<AppearanceTunerRoot> {
    private var appRoot: UIViewController? {
        view.window?.windowScene?.windows.first { !($0 is AppearanceTunerWindow) }?.rootViewController
    }
    override var prefersStatusBarHidden: Bool { appRoot?.prefersStatusBarHidden ?? false }
    override var preferredStatusBarStyle: UIStatusBarStyle { appRoot?.preferredStatusBarStyle ?? .default }
}

// MARK: - Root: the handle or the sheet

struct AppearanceTunerRoot: View {
    weak var window: AppearanceTunerWindow?
    @State private var tuner = AppearanceTuner.shared
    @State private var expanded = UserDefaults.standard.bool(forKey: "AppearanceTunerOpen")   // DEBUG stills
    @State private var handlePos: CGPoint? = nil
    @State private var handleDrag: CGSize = .zero
    @State private var sheetY: CGFloat? = nil       // the sheet's top edge; nil = docked at the bottom
    @State private var sheetDrag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if tuner.hiddenUntilRelaunch {
                    Color.clear
                } else if expanded {
                    sheet(in: geo)
                } else {
                    handle(in: size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .onChange(of: tuner.hiddenUntilRelaunch) { _, hidden in if hidden { window?.touchRects = [] } }
    }

    // The handle — a small pill with a slider glyph.
    private func handle(in size: CGSize) -> some View {
        let base = handlePos ?? CGPoint(x: size.width - 34, y: size.height * 0.30)
        let p = CGPoint(x: min(max(base.x + handleDrag.width, 24), size.width - 24),
                        y: min(max(base.y + handleDrag.height, 60), size.height - 40))
        return Image(systemName: "slider.horizontal.3")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
            // Measured and made touchable BEFORE `.position` (which would make it the whole screen).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { window?.touchRects = [$0] }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { handleDrag = $0.translation }
                .onEnded { _ in handlePos = p; handleDrag = .zero })
            .onTapGesture { expanded = true }
            .onLongPressGesture(minimumDuration: 0.6) { tuner.hiddenUntilRelaunch = true }
            .accessibilityElement()
            .accessibilityLabel("Appearance tuner")
            .accessibilityHint("Tap to open. Long-press to hide until the next launch.")
            .accessibilityIdentifier("appearanceTunerHandle")
            .accessibilityAddTraits(.isButton)
            .position(p)
    }

    // The sheet — full width, ~44% of the height, movable by its header.
    private func sheet(in geo: GeometryProxy) -> some View {
        let size = geo.size
        let h = min(430, size.height * 0.44)
        let minY = geo.safeAreaInsets.top + 4
        let maxY = size.height - h - max(geo.safeAreaInsets.bottom, 8)
        let y = min(max((sheetY ?? maxY) + sheetDrag, minY), maxY)
        return AppearanceTunerSheet(
            tuner: tuner,
            onClose: { expanded = false },
            onDock: { sheetY = (sheetY ?? maxY) > (minY + maxY) / 2 ? minY : maxY },
            headerDrag: DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { sheetDrag = $0.translation.height }
                .onEnded { _ in sheetY = y; sheetDrag = 0 })
            .frame(width: size.width - 16, height: h)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { window?.touchRects = [$0] }   // inside the offset → moved frame
            .offset(x: 8, y: y)
    }
}

// MARK: - The sheet

struct AppearanceTunerSheet<G: Gesture>: View {
    @Bindable var tuner: AppearanceTuner
    let onClose: () -> Void
    let onDock: () -> Void
    let headerDrag: G
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    @State private var confirmReset = false

    private var dark: Bool { colorScheme == .dark }
    private var v: AppearanceTuningValues { tuner.values(dark: dark) }
    private func set(_ change: @escaping (inout AppearanceTuningValues) -> Void) { tuner.update(dark: dark, change) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    cardContentSection
                    captureControlsSection
                    librarianSection
                    gradedSection
                    cardsSection
                    heroFadeSection
                    actions
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.visible)
        }
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
        .accessibilityElement(children: .contain)   // a container, so the controls keep their own identifiers
        .accessibilityIdentifier("appearanceTunerSheet")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Capsule().fill(.secondary.opacity(0.6)).frame(width: 30, height: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text("Appearance tuner").font(.subheadline.weight(.semibold))
                // The mode row: which appearance these controls edit.
                Text("Editing \(dark ? "Dark" : "Light") — follows the system")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.62))
                    .accessibilityIdentifier("tunerEditingMode")
            }
            Spacer()
            Button(action: onDock) { Image(systemName: "arrow.up.and.down") }
                .accessibilityLabel("Move to the other edge")
            Button(action: onClose) { Image(systemName: "chevron.down.circle.fill").font(.title3) }
                .accessibilityLabel("Close the tuner")
                .accessibilityIdentifier("tunerClose")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(headerDrag)
    }

    // Librarian surface — live-24 (1): two modes. Frost = our blur + tint; Liquid Glass = Apple's glass (variant +
    // tint) + our reading veil. A glass control never kicks the panel out of Liquid Glass.

    private var librarianSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Librarian surface", value: (v.panelMode == .glass ? "Liquid Glass" : v.panel.label)
                         + (v.glassControls ? " · glass controls" : ""))
            Picker("Panel", selection: Binding(get: { v.panelMode }, set: { m in
                set { $0.panelMode = m; if m == .frost && $0.panel == .liquidGlass { $0.panel = .custom } }
            })) {
                ForEach(LibrarianPanelMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tunerPanelMode")
            if v.panelMode == .frost { frostControls } else { glassControls }
            toggle("Glass controls (search pill + Ask bar)", v.glassControls, id: "glassControls") { b in set { $0.glassControls = b } }
            toggle("Dim content behind", v.dimBehind, id: "dim") { b in set { $0.dimBehind = b } }
            if v.dimBehind {
                slider("Dim", v.dimAmount, 0...0.20, 0.005, String(format: "%.0f%%", v.dimAmount * 100), id: "dimAmount") { x in
                    set { $0.dimAmount = x }
                }
            }
        }
    }

    @ViewBuilder private var frostControls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(LibrarianPanelPreset.offered) { p in
                    chip(p.label, selected: v.panel == p, id: "tunerPreset-\(p.rawValue)") { set { $0.apply(p) } }
                }
            }
        }
        .scrollIndicators(.hidden)
        if v.panel == .today {
            note(dark ? "Before = the Solar Flare panel (before live-23). A slider starts a custom frost." :
                        "Before = thin material, tint 0.35 (before live-23). A slider starts a custom frost.")
        }
        slider("Tint opacity", v.tintOpacity, 0...1, 0.01, String(format: "%.2f", v.tintOpacity), id: "tint") { x in
            set { $0.editFrost { $0.tintOpacity = x } }
        }
        slider("Blur", v.blur, 0...3, 0.01, blurReadout(v.blur), id: "blur") { x in set { $0.editFrost { $0.blur = x } } }
        slider("Backdrop saturation", v.saturation, 0...1, 0.01, String(format: "%.0f%%", v.saturation * 100), id: "saturation") { x in
            set { $0.editFrost { $0.saturation = x } }
        }
    }

    @ViewBuilder private var glassControls: some View {
        let g = v.glass
        Picker("Variant", selection: Binding(get: { g.variant }, set: { x in set { $0.editGlass { $0.variant = x } } })) {
            ForEach(GlassVariant.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tunerGlassVariant")
        tintColorPicker("Glass tint", g.tint, id: "tunerGlassTint") { c in set { $0.editGlass { $0.tint = c } } }
        slider("Tint strength", g.tintStrength, 0...0.80, 0.01, String(format: "%.0f%%", g.tintStrength * 100), id: "glassTintStrength") { x in
            set { $0.editGlass { $0.tintStrength = x } }
        }
        slider("Reading veil (behind the transcript)", g.veil, 0...1, 0.01, String(format: "%.0f%%", g.veil * 100), id: "veil") { x in
            set { $0.editGlass { $0.veil = x } }
        }
        note("Apple's Liquid Glass offers a variant and a tint only; blur and refraction are the system's (and iOS 27's "
             + "Liquid Glass slider in Settings). The veil is ours: a soft-edged layer behind the text, edges left lensing.")
    }

    // Graded tint — live-24 (2): the Siri-style pill and the graded panel.

    private var gradedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Graded tint", value: [v.pillGrade.on ? "pill" : nil, v.panelGrade.on ? "panel" : nil,
                                                v.pillRim.on ? "rim" : nil].compactMap { $0 }.joined(separator: " · ").ifEmpty("off"))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(LibrarianGlassPreset.allCases) { p in
                        chip(p.label, selected: v.matches(p, dark: dark), id: "tunerGlassPreset-\(p.rawValue)") {
                            set { $0.apply(p, dark: dark) }
                        }
                    }
                    chip("All off", selected: false, id: "tunerGlassPreset-off") {
                        set { $0.pillGrade.on = false; $0.panelGrade.on = false; $0.pillRim.on = false }
                    }
                }
            }
            .scrollIndicators(.hidden)

            Text("Ask pill + search pill").font(.caption.weight(.semibold))
            toggle("Graded tint on the pills", v.pillGrade.on, id: "pillGrade") { b in set { $0.pillGrade.on = b } }
            if v.pillGrade.on {
                gradeControls(v.pillGrade, id: "pill") { change in set { change(&$0.pillGrade) } }
                Picker("Pill glass", selection: Binding(get: { v.pillVariant }, set: { x in set { $0.pillVariant = x } })) {
                    ForEach(GlassVariant.allCases) { Text("Glass: " + $0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tunerPillVariant")
            }
            toggle("Luminous rim", v.pillRim.on, id: "pillRim") { b in set { $0.pillRim.on = b } }
            if v.pillRim.on {
                slider("Rim width", v.pillRim.width, 0.5...2, 0.05, String(format: "%.2f pt", v.pillRim.width), id: "rimWidth") { x in
                    set { $0.pillRim.width = x }
                }
                slider("Rim brightness", v.pillRim.brightness, 0...1, 0.01, String(format: "%.0f%%", v.pillRim.brightness * 100),
                       id: "rimBrightness") { x in set { $0.pillRim.brightness = x } }
                HStack {
                    Text("Rim colour").font(.caption)
                    Spacer()
                    Text("#" + v.pillRim.color.hex).font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.62))
                        .accessibilityIdentifier("tunerReadout-rimColor")
                }
                Picker("Rim colour", selection: Binding(get: { v.pillRim.color }, set: { c in set { $0.pillRim.color = c } })) {
                    ForEach(PillRimColor.allCases) { Text($0 == .cyan ? "Cyan" : $0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tunerRimColor")
                Picker("While answering", selection: Binding(get: { v.pillRim.animation }, set: { a in set { $0.pillRim.animation = a } })) {
                    ForEach(PillRimAnimation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tunerRimAnimation")
                note("AirPad's palette only — never Apple's multicolour Apple Intelligence edge. The rim moves only while an "
                     + "answer is generating, and stays still with Reduce Motion.")
            }

            Text("Panel").font(.caption.weight(.semibold))
            toggle("Graded tint on the panel", v.panelGrade.on, id: "panelGrade") { b in set { $0.panelGrade.on = b } }
            if v.panelGrade.on {
                gradeControls(v.panelGrade, id: "panel") { change in set { change(&$0.panelGrade) } }
            }
        }
    }

    @ViewBuilder
    private func gradeControls(_ g: GradedTint, id: String, _ edit: @escaping (@escaping (inout GradedTint) -> Void) -> Void) -> some View {
        slider("Tint at the top", g.top, 0...1, 0.01, String(format: "%.0f%%", g.top * 100), id: "\(id)GradeTop") { x in edit { $0.top = x } }
        slider("Tint at the bottom", g.bottom, 0...1, 0.01, String(format: "%.0f%%", g.bottom * 100), id: "\(id)GradeBottom") { x in
            edit { $0.bottom = x }
        }
        slider("Fade start", g.start, 0...1, 0.01, String(format: "%.2f", g.start), id: "\(id)GradeStart") { x in edit { $0.start = x } }
        slider("Softness", g.softness, 0...1, 0.01, String(format: "%.2f", g.softness), id: "\(id)GradeSoftness") { x in
            edit { $0.softness = x }
        }
        Picker("Direction", selection: Binding(get: { g.direction }, set: { d in edit { $0.direction = d } })) {
            ForEach(GradeDirection.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tuner\(id.capitalized)GradeDirection")
        tintColorPicker("Grade colour", g.color, id: "tuner\(id.capitalized)GradeColor") { c in edit { $0.color = c } }
    }

    private func tintColorPicker(_ label: String, _ c: GlassTintColor, id: String, _ onChange: @escaping (GlassTintColor) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("#" + c.hex).font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.62))
                    .accessibilityIdentifier(id + "-hex")
            }
            Picker(label, selection: Binding(get: { c }, set: onChange)) {
                ForEach(GlassTintColor.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(id)
        }
    }

    private func chip(_ label: String, selected: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(selected ? 0.16 : 0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0.5 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func blurReadout(_ b: Double) -> String {
        String(format: "%.2f pass%@", b, b == 1 ? "" : "es")
    }

    // Cards / field

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Cards / field", value: dark ? "dark" : v.palette)
            if dark {
                note("Palettes L1 / L2 / L3 are light-mode only.")
            } else {
                Picker("Palette", selection: Binding(get: { v.palette }, set: { p in set { $0.palette = p } })) {
                    ForEach(AppearanceTuning.palettes, id: \.name) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tunerPalette")
            }
            let fieldHex = AppearanceTuning.fieldHex(v, dark: dark)
            slider("Field brightness", v.fieldStep, -1...2, 0.05,
                   "\(AppearanceTuning.fieldLabel(v.fieldStep)) · #\(fieldHex)", id: "field") { x in set { $0.fieldStep = x } }
            let ref = dark ? AppearanceTuning.darkShadowAlpha : CardSurfaceDefaults.referenceShadowAlpha
            slider("Shadow opacity (of today's)", v.shadowStrength, 0...1, 0.01,
                   String(format: "%.0f%% · α %.3f", v.shadowStrength * 100, v.shadowStrength * ref), id: "shadow") { x in
                set { $0.shadowStrength = x }
            }
            slider("Shadow radius", v.shadowRadius, 0...40, 0.5, String(format: "%.1f", v.shadowRadius), id: "shadowRadius") { x in
                set { $0.shadowRadius = x }
            }
            toggle(dark ? "Hairline (white, all edges)" : "Hairline (black, all edges)", v.hairline, id: "hairline") { b in
                set { $0.hairline = b }
            }
            if v.hairline {
                slider("Hairline width", v.hairlineWidth, 0...1, 0.05, String(format: "%.2f pt", v.hairlineWidth), id: "hairlineWidth") { x in
                    set { $0.hairlineWidth = x }
                }
                slider("Hairline opacity", v.hairlineOpacity, 0...1, 0.01, String(format: "%.2f", v.hairlineOpacity), id: "hairlineOpacity") { x in
                    set { $0.hairlineOpacity = x }
                }
            } else {
                note(dark ? "Off: today's dark top rim." : "Off: the white top rim from before live-22.")
            }
        }
    }

    // Card content (live-23 (4)) — both appearances

    private var cardContentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Card content", value: tuner.state.cardContent.label)
            Picker("Card content", selection: Binding(get: { tuner.state.cardContent }, set: { tuner.state.cardContent = $0 })) {
                ForEach(CardContentMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tunerCardContent")
            note(tuner.state.cardContent == .today
                 ? "Today: the faces as they ship. Proposal: a content strip (type symbols + counts), one preview, real list markers."
                 : "Proposal: content strip, one preview from the richest item, real list markers; grid 3-col adapts its title.")
        }
    }

    // Capture controls (live-23 (5c)) — both appearances

    private var captureControlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Capture controls", value: tuner.state.captureControls.label)
            Picker("Capture controls", selection: Binding(get: { tuner.state.captureControls },
                                                         set: { tuner.state.captureControls = $0 })) {
                ForEach(CaptureControlsMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tunerCaptureControls")
            note("Quick Capture, \"+\" Capture and the voice recorder. Glass: item types in one glass cluster, Done "
                 + "prominent, Delete red-tinted, Cancel plain. Reduce Transparency / Increase Contrast keep Today's pills.")
        }
    }

    // Hero photo fade (live-23 (3)) — carousel + grid cards

    private var heroFadeSection: some View {
        let f = v.heroFade
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Hero photo fade", value: dark ? "dark" : "light")
            slider("Fade length (of the hero zone)", v.fadeLength, 0.1...1.0, 0.01,
                   String(format: "%.2f", v.fadeLength), id: "fadeLength") { x in set { $0.fadeLength = x } }
            slider("Fade curve", v.fadeCurve, 0...2, 0.05, fadeCurveReadout(v.fadeCurve), id: "fadeCurve") { x in
                set { $0.fadeCurve = x }
            }
            note(String(format: "The photo runs %.0f%% past the hero zone and fades over its last %.0f%%. live-22 was linear over the last 22%%.",
                        f.overshoot * 100, f.length * 100))
        }
    }

    private func fadeCurveReadout(_ c: Double) -> String {
        switch c {
        case ..<0.025: return "linear"
        case 0.975..<1.025: return "smoothstep"
        case 1.975...: return "smootherstep"
        default: return String(format: "%.2f", c)
        }
    }

    // Copy + reset

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy values") {
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    UIPasteboard.general.string = AppearanceTuning.exportJSON(tuner.state, editing: dark ? "dark" : "light", build: build)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tunerCopy")
                Button(confirmReset ? "Tap again to reset" : "Reset to defaults", role: .destructive) {
                    if confirmReset { tuner.reset(); confirmReset = false } else {
                        confirmReset = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmReset = false }
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("tunerReset")
            }
            note("Copy values copies both appearances as JSON. Reset restores T's tuned values (2026-10-16), both modes. "
                 + "Drag the header to move this sheet; long-press the handle to hide it until the next launch. "
                 + "Values stay on this iPhone. TestFlight only.")
        }
    }

    // Rows

    private func sectionTitle(_ t: String, value: String) -> some View {
        HStack {
            Text(t).font(.footnote.weight(.semibold))
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.62))
        }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.caption2).foregroundStyle(Color.primary.opacity(0.62)).fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ step: Double, _ readout: String,
                        id: String, _ onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(readout).font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.62))
                    .accessibilityIdentifier("tunerReadout-\(id)")
            }
            Slider(value: Binding(get: { value }, set: { onChange(($0 / step).rounded() * step) }), in: range)
                .controlSize(.small)
                .accessibilityIdentifier("tunerSlider-\(id)")
                .accessibilityValue(readout)
        }
    }

    private func toggle(_ label: String, _ on: Bool, id: String, _ onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: onChange)) { Text(label).font(.caption) }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("tunerToggle-\(id)")
    }
}
private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif
