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
    @State private var tall = false                 // 44% ↔ 70% of the screen (session only)

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

    // The sheet — full width, ~44% of the height (70% when tall), movable by its header.
    private func sheet(in geo: GeometryProxy) -> some View {
        let size = geo.size
        let h = tall ? size.height * 0.70 : min(430, size.height * 0.44)
        let minY = geo.safeAreaInsets.top + 4
        let maxY = size.height - h - max(geo.safeAreaInsets.bottom, 8)
        let y = min(max((sheetY ?? maxY) + sheetDrag, minY), maxY)
        return AppearanceTunerSheet(
            tuner: tuner,
            onClose: { expanded = false },
            onDock: { sheetY = (sheetY ?? maxY) > (minY + maxY) / 2 ? minY : maxY },
            tall: $tall,
            headerDrag: DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { sheetDrag = $0.translation.height }
                .onEnded { _ in sheetY = y; sheetDrag = 0 })
            .frame(width: size.width - 16, height: h)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { window?.touchRects = [$0] }   // inside the offset → moved frame
            .offset(x: 8, y: y)
    }
}

// MARK: - The sheet

/// The sheet's sections — an accordion (2026-10-17 brief: T scrolled a lot and brushed sliders by accident). All start
/// closed; opening one closes the others; the open one is remembered (`AppearanceTuning.openSectionKey`).
enum TunerSection: String, CaseIterable, Identifiable {
    case cardContent, captureControls, floatingButtons, librarian, peekPill, searchPill, askPill, panelGrade, cards, heroFade
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cardContent:     return "Card content"
        case .captureControls: return "Capture controls"
        case .floatingButtons: return "Floating buttons"
        case .librarian:       return "Librarian surface"
        case .peekPill:        return "Peek pill"
        case .searchPill:      return "Search pill"
        case .askPill:         return "Ask bar"
        case .panelGrade:      return "Panel grade"
        case .cards:           return "Cards / field"
        case .heroFade:        return "Hero photo fade"
        }
    }
}

/// Which pill a pill section edits.
enum PillSurface: String {
    case peek, search, ask
}

struct AppearanceTunerSheet<G: Gesture>: View {
    @Bindable var tuner: AppearanceTuner
    let onClose: () -> Void
    let onDock: () -> Void
    @Binding var tall: Bool
    let headerDrag: G
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    @State private var confirmReset = false
    @State private var locked = false              // session only
    @AppStorage(AppearanceTuning.openSectionKey) private var openSection = ""

    private var dark: Bool { colorScheme == .dark }
    private var v: AppearanceTuningValues { tuner.values(dark: dark) }
    private func set(_ change: @escaping (inout AppearanceTuningValues) -> Void) { tuner.update(dark: dark, change) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TunerSection.allCases) { group($0) }
                    note("Copy values copies both appearances as JSON. Reset restores the TestFlight defaults, both modes. "
                         + "Drag the header to move this sheet; long-press the handle to hide it until the next launch. "
                         + "Sliders move only when dragged by the knob. Values stay on this iPhone. TestFlight only.")
                        .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.visible)
            Divider().opacity(0.5)
            actions
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
        .accessibilityElement(children: .contain)   // a container, so the controls keep their own identifiers
        .accessibilityIdentifier("appearanceTunerSheet")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Capsule().fill(.secondary.opacity(0.6)).frame(width: 30, height: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text("Appearance tuner").font(.subheadline.weight(.semibold))
                // The mode row: which appearance these controls edit.
                Text("Editing \(dark ? "Dark" : "Light") — follows the system")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.62))
                    .accessibilityIdentifier("tunerEditingMode")
            }
            Spacer()
            Button { locked.toggle() } label: { Image(systemName: locked ? "lock.fill" : "lock.open") }
                .accessibilityLabel(locked ? "Unlock the controls" : "Lock the controls")
                .accessibilityIdentifier("tunerLock")
                .accessibilityValue(locked ? "locked" : "unlocked")
            Button { tall.toggle() } label: {
                Image(systemName: tall ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
                .accessibilityLabel(tall ? "Make the tuner shorter" : "Make the tuner taller")
                .accessibilityIdentifier("tunerTall")
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

    // MARK: Sections (accordion)

    private func group(_ section: TunerSection) -> some View {
        let open = openSection == section.rawValue
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                openSection = open ? "" : section.rawValue
            } label: {
                HStack(spacing: 8) {
                    Text(section.title).font(.footnote.weight(.semibold))
                    Spacer()
                    Text(summary(section)).font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.62))
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tunerSection-\(section.rawValue)")
            .accessibilityValue(open ? "open" : "closed")
            if open {
                VStack(alignment: .leading, spacing: 10) { content(section) }
                    .disabled(locked)
                    .opacity(locked ? 0.45 : 1)
                    .padding(.bottom, 6)
            }
            Divider().opacity(0.4)
        }
        .padding(.top, 6)
    }

    @ViewBuilder private func content(_ section: TunerSection) -> some View {
        switch section {
        case .cardContent:     cardContentSection
        case .captureControls: captureControlsSection
        case .floatingButtons: floatingButtonsSection
        case .librarian:       librarianSection
        case .peekPill:        pillSection(.peek)
        case .searchPill:      pillSection(.search)
        case .askPill:         pillSection(.ask)
        case .panelGrade:      panelGradeSection
        case .cards:           cardsSection
        case .heroFade:        heroFadeSection
        }
    }

    /// The one-line value a closed header shows.
    private func summary(_ section: TunerSection) -> String {
        switch section {
        case .cardContent:     return tuner.state.cardContent.label
        case .captureControls: return tuner.state.captureControls.label
        case .floatingButtons: return tuner.state.floatingButtons.label
        case .librarian:       return (v.panelMode == .glass ? "Liquid Glass" : v.panel.label) + (v.glassControls ? " · glass controls" : "")
        case .peekPill:        return pillSummary(v.peekPill, answering: false)
        case .searchPill:      return pillSummary(v.searchPill, answering: true)
        case .askPill:         return v.askMatchesSearch ? "matches Search" : pillSummary(v.askPill, answering: true)
        case .panelGrade:      return v.panelGrade.on ? String(format: "%.0f%% → %.0f%%", v.panelGrade.top * 100, v.panelGrade.bottom * 100) : "off"
        case .cards:           return dark ? "dark" : v.palette
        case .heroFade:        return String(format: "%.2f · %@ · into %.0f%%", v.fadeLength, fadeCurveReadout(v.fadeCurve), v.fadeIntoBody * 100)
        }
    }

    private func pillSummary(_ p: PillLook, answering: Bool) -> String {
        [p.variant.label, p.grade.on ? "graded" : nil, p.rim.rest == .off ? nil : "rim \(p.rim.rest.label.lowercased())",
         answering && p.rim.active != .none ? p.rim.active.label.lowercased() : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // Librarian surface — live-24 (1): two modes. Frost = our blur + tint; Liquid Glass = Apple's glass (variant +
    // tint) + our reading veil. A glass control never kicks the panel out of Liquid Glass.

    @ViewBuilder private var librarianSection: some View {
        Picker("Panel", selection: Binding(get: { v.panelMode }, set: { m in
            set { $0.panelMode = m; if m == .frost && $0.panel == .liquidGlass { $0.panel = .custom } }
        })) {
            ForEach(LibrarianPanelMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tunerPanelMode")
        if v.panelMode == .frost { frostControls } else { glassControls }
        toggle("Glass controls (the pills + Ask bar)", v.glassControls, id: "glassControls") { b in set { $0.glassControls = b } }
        toggle("Dim content behind", v.dimBehind, id: "dim") { b in set { $0.dimBehind = b } }
        if v.dimBehind {
            slider("Dim", v.dimAmount, 0...0.20, 0.005, String(format: (v.dimAmount * 1000).rounded().truncatingRemainder(dividingBy: 10) == 0
                                                                 ? "%.0f%%" : "%.1f%%", v.dimAmount * 100), id: "dimAmount") { x in
                set { $0.dimAmount = x }
            }
        }
        subhead("Graded presets (all three pills + the panel)")
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(LibrarianGlassPreset.allCases) { p in
                    chip(p.label, selected: v.matches(p, dark: dark), id: "tunerGlassPreset-\(p.rawValue)") {
                        set { $0.apply(p, dark: dark) }
                    }
                }
                chip("All off", selected: false, id: "tunerGlassPreset-off") {
                    set { $0.panelGrade.on = false; $0.editPills { $0.grade.on = false; $0.rim.rest = .off; $0.rim.active = .none } }
                }
            }
        }
        .scrollIndicators(.hidden)
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

    // The pills — 2026-10-17 brief: peek, search and Ask each have their own glass, grade and rim.

    private func pill(_ s: PillSurface) -> PillLook {
        switch s {
        case .peek:   return v.peekPill
        case .search: return v.searchPill
        case .ask:    return v.askPill
        }
    }
    private func editPill(_ s: PillSurface, _ change: @escaping (inout PillLook) -> Void) {
        set { values in
            switch s {
            case .peek:   change(&values.peekPill)
            case .search: change(&values.searchPill)
            case .ask:    change(&values.askPill)
            }
        }
    }

    @ViewBuilder private func pillSection(_ s: PillSurface) -> some View {
        let id = s.rawValue
        switch s {
        case .peek:
            note("The resting pill at the bottom of the panel. It is the same view as the search pill: as the panel "
                 + "opens, this look hands over to the search pill's. It never answers, so it has no \"while answering\".")
        case .search:
            note("The peek pill once the panel is open (it grows out of it).")
        case .ask:
            toggle("Match Search", v.askMatchesSearch, id: "askMatchesSearch") { b in set { $0.setAskMatchesSearch(b) } }
        }
        if s == .ask && v.askMatchesSearch {
            note("The Ask bar mirrors the search pill. Turn this off to tune it on its own; it starts from the search pill's values.")
        } else {
            let p = pill(s)
            if !v.glassControls {
                note("These show only with Glass controls on (Librarian surface).")
            }
            subhead("Glass + grade")
            Picker("Glass", selection: Binding(get: { p.variant }, set: { x in editPill(s) { $0.variant = x } })) {
                ForEach(GlassVariant.allCases) { Text("Glass: " + $0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tunerPillVariant-\(id)")
            toggle("Graded tint", p.grade.on, id: "\(id)Grade") { b in editPill(s) { $0.grade.on = b } }
            if p.grade.on {
                gradeControls(p.grade, id: id) { change in editPill(s) { change(&$0.grade) } }
            }

            subhead("Rim at rest")
            Picker("Rim at rest", selection: Binding(get: { p.rim.rest }, set: { r in editPill(s) { $0.rim.rest = r } })) {
                ForEach(PillRimRest.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tunerRimRest-\(id)")
            if p.rim.rest != .off {
                slider("Brightness at rest", p.rim.brightness, 0...1, 0.01, String(format: "%.0f%%", p.rim.brightness * 100),
                       id: "\(id)RimBrightness") { x in editPill(s) { $0.rim.brightness = x } }
            }
            if p.rim.isUsed {
                slider("Rim width", p.rim.width, 0.5...2, 0.05, String(format: "%.2f pt", p.rim.width), id: "\(id)RimWidth") { x in
                    editPill(s) { $0.rim.width = x }
                }
                HStack {
                    Text("Rim colour").font(.caption)
                    Spacer()
                    Text("#" + p.rim.color.hex).font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.62))
                        .accessibilityIdentifier("tunerReadout-\(id)RimColor")
                }
                Picker("Rim colour", selection: Binding(get: { p.rim.color }, set: { c in editPill(s) { $0.rim.color = c } })) {
                    ForEach(PillRimColor.allCases) { Text($0 == .cyan ? "Cyan" : $0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tunerRimColor-\(id)")
            }

            if s != .peek {
                subhead("Rim while answering")
                Picker("While answering", selection: Binding(get: { p.rim.active }, set: { a in editPill(s) { $0.rim.active = a } })) {
                    ForEach(PillRimActive.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tunerRimActive-\(id)")
                if p.rim.active != .none {
                    slider("Peak brightness", p.rim.activeBrightness, 0...1, 0.01,
                           String(format: "%.0f%%", p.rim.activeBrightness * 100), id: "\(id)RimActiveBrightness") { x in
                        editPill(s) { $0.rim.activeBrightness = x }
                    }
                }
                note("AirPad's palette only — never Apple's multicolour Apple Intelligence edge. Runs only while an answer is "
                     + "generating, fades in and out, and stays still with Reduce Motion.")
            }
        }
    }

    // Panel grade — live-24 (2)

    @ViewBuilder private var panelGradeSection: some View {
        toggle("Graded tint on the panel", v.panelGrade.on, id: "panelGrade") { b in set { $0.panelGrade.on = b } }
        if v.panelGrade.on {
            gradeControls(v.panelGrade, id: "panel") { change in set { change(&$0.panelGrade) } }
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

    @ViewBuilder private var cardsSection: some View {
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

    // Card content (live-23 (4)) — both appearances

    @ViewBuilder private var cardContentSection: some View {
        Picker("Card content", selection: Binding(get: { tuner.state.cardContent }, set: { tuner.state.cardContent = $0 })) {
            ForEach(CardContentMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tunerCardContent")
        note(tuner.state.cardContent == .today
             ? "Before: the faces before live-23. Proposal (what ships): a content strip (type symbols + counts), one preview, real list markers."
             : "Proposal (what ships): content strip, one preview from the richest item, real list markers; grid 3-col adapts its title.")
    }

    // Capture controls (live-23 (5c)) — both appearances

    @ViewBuilder private var captureControlsSection: some View {
        Picker("Capture controls", selection: Binding(get: { tuner.state.captureControls },
                                                     set: { tuner.state.captureControls = $0 })) {
            ForEach(CaptureControlsMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tunerCaptureControls")
        note("Quick Capture, \"+\" Capture and the voice recorder. Glass (what ships): item types in one glass cluster, Done "
             + "prominent, Delete red-tinted, Cancel plain. Before: the solid pills, which Reduce Transparency / Increase Contrast keep.")
    }

    // Floating buttons (live-26 (3d)) — both appearances

    @ViewBuilder private var floatingButtonsSection: some View {
        Picker("Floating buttons", selection: Binding(get: { tuner.state.floatingButtons },
                                                     set: { tuner.state.floatingButtons = $0 })) {
            ForEach(FloatingButtonsMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tunerFloatingButtons")
        note("The \"+\" and the view switcher, bottom right. Glass: \"+\" prominent glass (the primary action), the view "
             + "switcher regular glass like the top bar, merged as one. Today: two solid ink discs (what the App Store build "
             + "shows until you confirm Glass). Reduce Transparency / Increase Contrast keep the discs.")
    }

    // Hero photo fade (live-23 (3)) — carousel + grid cards

    @ViewBuilder private var heroFadeSection: some View {
        let f = v.heroFade
        slider("Fade length (of the hero zone)", v.fadeLength, 0.1...1.0, 0.01,
               String(format: "%.2f", v.fadeLength), id: "fadeLength") { x in set { $0.fadeLength = x } }
        slider("Fade curve", v.fadeCurve, 0...2, 0.05, fadeCurveReadout(v.fadeCurve), id: "fadeCurve") { x in
            set { $0.fadeCurve = x }
        }
        // live-26 (3c) — how far the photo carries down into the body (0 = before live-26 … 1 = to the title block's bottom).
        slider("Fade into body", v.fadeIntoBody, 0...1, 0.01, String(format: "%.0f%%", v.fadeIntoBody * 100), id: "fadeIntoBody") { x in
            set { $0.fadeIntoBody = x }
        }
        let m = CardHeroFade.matchFluted(dark: dark)
        chip("Match fluted", selected: v.fadeLength == m.length && v.fadeCurve == m.curve && v.fadeIntoBody == m.intoBody,
             id: "tunerFadeMatchFluted") {
            set { $0.fadeLength = m.length; $0.fadeCurve = m.curve; $0.fadeIntoBody = m.intoBody }
        }
        // live-28 (A1) — light only: Today / A / B (the App Store build keeps Today until you pick).
        if !dark {
            Picker("Light fade", selection: Binding(get: { tuner.state.lightFade }, set: { tuner.state.lightFade = $0 })) {
                ForEach(LightFadeMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tunerLightFade")
            note("Light fade. Today: the veil behind the card text starts inside the hero zone. A: only a soft band behind the "
                 + "dateline; above it, your fade alone. B: A, and the fade holds the photo longer, then falls faster.")
        }
        note(String(format: "The photo runs %.0f%% past the hero zone and fades over %.0f%% of it. Fade into body carries it down "
                    + "toward the title block (100%% = to its bottom). Match fluted = the fluted cards' measured fade.",
                    CardHeroFade.run(f) * 100, f.length * 100))
    }

    private func fadeCurveReadout(_ c: Double) -> String {
        switch c {
        case ..<0.025: return "linear"
        case 0.975..<1.025: return "smoothstep"
        case 1.975...: return "smootherstep"
        default: return String(format: "%.2f", c)
        }
    }

    // Copy + reset — pinned below the scroll view, always reachable (and never locked).

    private var actions: some View {
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
            .disabled(locked)
            .accessibilityIdentifier("tunerReset")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    // Rows

    private func subhead(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).padding(.top, 2)
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
            TunerSlider(value: value, range: range, step: step, onChange: onChange)
                .accessibilityLabel(label)
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

/// The tuner's slider (2026-10-17 brief: T brushed sliders while scrolling the sheet). It moves ONLY when a drag starts
/// on its knob (a ~44 pt touch area around it); the track takes no touches at all, so a scroll swipe that crosses a
/// slider scrolls the sheet and leaves the value alone. VoiceOver / XCUITest see one adjustable element.
struct TunerSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onChange: (Double) -> Void
    @State private var dragFrom: Double? = nil

    private static let knob: CGFloat = 22, touch: CGFloat = 44

    private func snap(_ x: Double) -> Double {
        min(max((x / step).rounded() * step, range.lowerBound), range.upperBound)
    }
    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
    }

    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - Self.knob)
            let x = Self.knob / 2 + CGFloat(fraction) * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: x, height: 4)
            }
            .frame(height: geo.size.height)
            .allowsHitTesting(false)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .frame(width: Self.knob, height: Self.knob)
                .frame(width: Self.touch, height: Self.touch)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = dragFrom ?? value
                        if dragFrom == nil { dragFrom = value }
                        let span = range.upperBound - range.lowerBound
                        onChange(snap(start + Double(g.translation.width / travel) * span))
                    }
                    .onEnded { _ in dragFrom = nil })
                .position(x: x, y: geo.size.height / 2)
        }
        .frame(height: 30)
        // One adjustable element with the row's real frame (VoiceOver swipes up / down by a twentieth of the range).
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            let nudge = max(step, (range.upperBound - range.lowerBound) / 20)
            switch direction {
            case .increment: onChange(snap(value + nudge))
            case .decrement: onChange(snap(value - nudge))
            @unknown default: break
            }
        }
    }
}

#endif
