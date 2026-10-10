import SwiftUI
import UIKit
import CoreMotion
import simd

/// Fluted "void" glass (ws-fluted-glass). A domain warp inside `BlobField.metal` (`blobFieldGlass`)
/// that turns a blob surface into reeded glass over a black void: the field is only inferred
/// through thin refracted slivers at the rib edges. The field also shifts with the phone's tilt.
///
/// Values are BAKED from T's device dial (2026-10-07, TF 202610071510: "these defaults are great"):
/// the material in `BlobField.metal`, the per-surface sizes in `GlassSurface.spec`, the tilt range
/// in `GlassRender`, the re-centre time in `TiltIntegrator`.
///
/// Two user settings (Settings → Appearance and the canvas slide-out's Appearance section), both
/// ON by default and independent: **Fluted glass** and **Move with tilt**. Both off → every caller
/// gets nil → the untouched V1 `blobField` shader (V1 look, zero glass cost).
enum GlassSurface {
    case dashboard, entry, list, carousel, grid, photoCard

    /// nil = no glass on this surface. Photo (cover-image) cards keep the plain V1 floor glow: their
    /// blobs only pool under the text, so the glass read as an arbitrary half-faded band (T 2026-10-07).
    var spec: GlassSpec? {
        let r: Float = 3.155555486679077
        switch self {
        case .dashboard, .entry:
            return GlassSpec(ribs: 22, refraction: r, followsCard: false, fadeStart: 1, fadeEnd: 1, fadeAcross: false)
        case .list:
            // The list card's blob is pinned to the left column → the fade runs ACROSS, ending
            // before the text column.
            return GlassSpec(ribs: 20, refraction: r, followsCard: true, fadeStart: 0, fadeEnd: 0.46, fadeAcross: true)
        case .carousel:
            return GlassSpec(ribs: 30, refraction: r, followsCard: true, fadeStart: 0.3555555582046509, fadeEnd: 1, fadeAcross: false)
        case .grid:
            return GlassSpec(ribs: 29, refraction: r, followsCard: true, fadeStart: 0.2333333343267441, fadeEnd: 0.7111111283302307, fadeAcross: false)
        case .photoCard:
            return nil
        }
    }
}

/// Per-surface size. `ribs` = ribs per SCREEN width and `refraction` is width-normalised on every
/// surface, so a value means the same thing everywhere.
struct GlassSpec: Equatable {
    var ribs: Float
    var refraction: Float
    var followsCard: Bool     // false = ribs fixed to the screen; true = ribs ride with the card
    /// The glass eases back to the plain V1 field between fadeStart → fadeEnd (fractions of the
    /// surface, down or across), so the card's type zone reads as V1. start 1 = no fade.
    var fadeStart: Float
    var fadeEnd: Float
    var fadeAcross: Bool      // true = left → right; false = top → bottom
}

/// What one surface renders: ribbed glass, or the field moving with tilt and nothing else.
struct GlassRender: Equatable {
    var ribbed: Bool
    var spec: GlassSpec

    /// ± field travel at full tilt, fraction of the screen width.
    static let tiltX: Float = 0.05290258526802063
    static let tiltY: Float = 0.05533332824707031

    /// Shader buffer — order must match the GLASS layout in `BlobField.metal`.
    func packed(screenWidth: CGFloat, tilt: SIMD2<Float>) -> [Float] {
        [ribbed ? 1 : 2, Float(screenWidth), tilt.x * Self.tiltX, tilt.y * Self.tiltY,
         spec.ribs, spec.refraction, spec.followsCard ? 1 : 0,
         spec.fadeStart, spec.fadeEnd, spec.fadeAcross ? 1 : 0]
    }
}

/// The two Appearance settings + the system states that pause tilt. `@Observable` so only the
/// views that READ it re-render when a setting flips — no per-card `@AppStorage` (a UserDefaults
/// read on every body eval × every card).
@Observable
final class FlutedGlass {
    static let shared = FlutedGlass()

    enum Key {
        static let glass = "appearance.flutedGlass"
        static let tilt = "appearance.moveWithTilt"
    }

    var glassOn: Bool {
        didSet { UserDefaults.standard.set(glassOn, forKey: Key.glass); syncMotion() }
    }
    var tiltOn: Bool {
        didSet { UserDefaults.standard.set(tiltOn, forKey: Key.tilt); syncMotion() }
    }
    /// Low Power Mode pauses tilt only (the motion sensor stops; the glass stays — at the baked
    /// values it costs about the same as V1). Resumes by itself when Low Power Mode ends.
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var reduceMotion = UIAccessibility.isReduceMotionEnabled

    /// Tilt is actually moving the field.
    var tiltRunning: Bool { tiltOn && !lowPower && !reduceMotion }

    /// What `surface` should render, or nil → the untouched V1 shader.
    func active(_ surface: GlassSurface) -> GlassRender? {
        guard let spec = surface.spec else { return nil }
        if glassOn { return GlassRender(ribbed: true, spec: spec) }
        return tiltRunning ? GlassRender(ribbed: false, spec: spec) : nil
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let d = UserDefaults.standard
        // `bool(forKey:)` (not `as? Bool`) so a `-appearance.flutedGlass NO` launch arg reads too.
        glassOn = d.object(forKey: Key.glass) == nil ? true : d.bool(forKey: Key.glass)
        tiltOn = d.object(forKey: Key.tilt) == nil ? true : d.bool(forKey: Key.tilt)
        // Spike-build dials (TF GLASS SPIKE 1–6) are baked now.
        for k in ["glass.enabled", "glass.mode", "glass.tuning", "glass.tuning.light", "glass.sizes", "glass.recentre"] {
            d.removeObject(forKey: k)
        }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.syncMotion()
            },
            nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reduceMotion = UIAccessibility.isReduceMotionEnabled
                self?.syncMotion()
            },
        ]
        syncMotion()
    }

    /// Tilt runs only while something reads it — owned here, not by each BlobFieldView, so the
    /// view tree gains no lifecycle modifiers.
    private func syncMotion() {
        if tiltRunning { GlassMotion.shared.start() } else { GlassMotion.shared.stop() }
    }

    /// Rib phase is in screen space, normalised by the screen width.
    /// Read per frame, so resolved once (portrait app; the width doesn't change at runtime).
    static let screenWidth: CGFloat = {
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        return scene?.screen.bounds.width ?? 440
    }()
}

/// Gyro → a normalised tilt in −1…1 per axis. A LEAKY INTEGRATOR on the body-frame rotation rate:
/// each update adds the rotation since the last one and leaks back toward zero with time constant
/// `recentreSeconds`, so quick tilts move the glass and any resting grip becomes the centre.
///
/// Replaces the build-6/7 attitude version (T 2026-10-08: tilt "sticking and then sometimes totally
/// glitching out"). That one measured Euler roll/pitch against a saved reference: big posture
/// changes (lying down, flipping the phone) wrapped the angles → the glass snapped edge to edge,
/// and turning your body read as tilt that pinned the glass until the level caught up. Here there
/// is no reference, no Euler angle and no re-basing — each update moves the tilt by at most
/// |rate|·dt — so it cannot jump. Soft (tanh) edges, so it never pins at a clamp.
///
/// Read per frame inside the blob field's TimelineView (a plain, NON-observed read, so tilt never
/// invalidates a SwiftUI body).
final class GlassMotion {
    static let shared = GlassMotion()

    private let manager = CMMotionManager()
    private var integrator = TiltIntegrator()
    private var lastTimestamp: TimeInterval?
    private(set) var tilt = SIMD2<Float>(0, 0)
    private var running = false
    private var foregroundObserver: NSObjectProtocol?

    /// Matches the blob fields' 30 fps redraw: sampling faster than they draw is wasted CPU.
    private static let updateInterval: TimeInterval = 1.0 / 30.0

    private init() {
        // Coming back to the app → start centred, not from a stale tilt.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.recenter() }
    }

    func start() {
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        manager.deviceMotionUpdateInterval = Self.updateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let r = motion.rotationRate      // rad/s about the device axes, bias-corrected
            let dt = self.lastTimestamp.map { motion.timestamp - $0 } ?? 0
            self.lastTimestamp = motion.timestamp
            // x tilt = rotation about the device's long (y) axis, y tilt = about its short (x) axis.
            self.tilt = self.integrator.step(rate: SIMD2(r.y, r.x), dt: dt)
        }
    }

    /// Back to centre (next update starts from zero).
    func recenter() { integrator = TiltIntegrator(); lastTimestamp = nil; tilt = .zero }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
        recenter()
    }
}

/// The tilt maths, pure (no CoreMotion) so it can be exercised with synthetic rates.
struct TiltIntegrator {
    /// Time constant for a held tilt to ease back to centre (T 2026-10-07: "these defaults are great").
    static let recentreSeconds: Double = 2.0
    /// This many radians of accumulated rotation ≈ 76% travel (tanh(1)); the curve eases toward full.
    static let fullTiltRadians: Double = 0.35
    /// A gap longer than this (app paused, sensor stalled) → restart centred rather than integrate it.
    static let maxStep: Double = 0.25

    private(set) var angle = SIMD2<Double>(0, 0)

    mutating func step(rate: SIMD2<Double>, dt: Double) -> SIMD2<Float> {
        if dt <= 0 || dt > Self.maxStep {
            if dt > Self.maxStep { angle = .zero }
        } else {
            angle = angle * exp(-dt / Self.recentreSeconds) + rate * dt
            // Cap just past the visible range (tanh(2) ≈ 96%): a big move (flipping the phone)
            // would otherwise bank radians the leak takes seconds to drain → glass pinned at the edge.
            let cap = 2 * Self.fullTiltRadians
            angle = simd_clamp(angle, SIMD2(repeating: -cap), SIMD2(repeating: cap))
        }
        let d = angle / Self.fullTiltRadians
        return SIMD2(Float(tanh(d.x)), Float(tanh(d.y)))
    }
}

/// The two glass toggles, shared by Settings → Appearance (`detailed`: a subtitle under each) and
/// the canvas slide-out (compact: a status line only when tilt is paused).
struct GlassAppearanceToggles: View {
    var detailed: Bool
    @Environment(\.appBodyFont) private var appFont
    private var glass: FlutedGlass { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: detailed ? 16 : 4) {
            row("Fluted glass",
                detail: detailed ? "Reeded glass over the color on cards and the Dashboard." : nil,
                isOn: Binding(get: { glass.glassOn }, set: { glass.glassOn = $0 }))
            row("Move with tilt",
                detail: tiltDetail,
                isOn: Binding(get: { glass.tiltOn && !glass.reduceMotion }, set: { glass.tiltOn = $0 }))
                .disabled(glass.reduceMotion)
        }
    }

    private var tiltDetail: String? {
        if glass.reduceMotion { return "Off while Reduce Motion is on" }
        if glass.tiltOn && glass.lowPower { return "Paused in Low Power Mode" }
        return detailed ? "The color shifts slightly as you tilt your phone." : nil
    }

    private func row(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(appFont.font(size: 15, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppearancePalette.ink)
                if let detail {
                    Text(detail).font(appFont.font(size: 12, relativeTo: .caption1))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
            }
        }
        .tint(.purple)
    }
}
