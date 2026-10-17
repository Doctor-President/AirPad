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
    /// A Librarian slider turns a preset into Custom (Liquid Glass and Today aren't slider-built).
    private func setPanel(_ change: @escaping (inout AppearanceTuningValues) -> Void) {
        set { change(&$0); $0.panel = .custom }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    librarianSection
                    cardsSection
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

    // Librarian surface

    private var librarianSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Librarian surface", value: v.panel.label + (v.glassControls ? " · glass controls" : ""))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(LibrarianPanelPreset.offered) { p in
                        Button { set { $0.apply(p) } } label: {
                            Text(p.label).font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.primary.opacity(v.panel == p ? 0.16 : 0.06)))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(v.panel == p ? 0.5 : 0), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tunerPreset-\(p.rawValue)")
                        .accessibilityAddTraits(v.panel == p ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            if v.panel == .today {
                note(dark ? "Today is the Solar Flare panel. A slider starts a custom frost." :
                            "Today: thin material, tint 0.35. A slider starts a custom frost.")
            } else if v.panel == .liquidGlass {
                note("The whole panel is Liquid Glass (regular). The sliders below build a frost instead.")
            }
            slider("Tint opacity", v.tintOpacity, 0...1, 0.01, String(format: "%.2f", v.tintOpacity), id: "tint") { x in
                setPanel { $0.tintOpacity = x }
            }
            slider("Blur", v.blur, 0...3, 0.01, blurReadout(v.blur), id: "blur") { x in setPanel { $0.blur = x } }
            slider("Backdrop saturation", v.saturation, 0...1, 0.01, String(format: "%.0f%%", v.saturation * 100), id: "saturation") { x in
                setPanel { $0.saturation = x }
            }
            toggle("Glass controls (search pill + Ask bar)", v.glassControls, id: "glassControls") { b in set { $0.glassControls = b } }
            toggle("Dim content behind", v.dimBehind, id: "dim") { b in set { $0.dimBehind = b } }
            if v.dimBehind {
                slider("Dim", v.dimAmount, 0...0.20, 0.005, String(format: "%.0f%%", v.dimAmount * 100), id: "dimAmount") { x in
                    set { $0.dimAmount = x }
                }
            }
        }
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
            note("Copy values copies both appearances as JSON. Reset restores T's picks (light) and today (dark), both modes. "
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
#endif
