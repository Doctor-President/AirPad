import Foundation
import StoreKit
import Observation

/// pro-build — the user's Map look: ONE pick, paired across the Maps as the looks always were (Glass ↔ Glass with each
/// Map's own values; Aura / Eclipse ↔ Wash; Riso, Gradient, Outline on both). Flat is free; every other look needs Pro.
/// The pick survives a lost entitlement (a refund shows Flat, and the pick comes back with Pro). Fresh install = Flat.
/// Static + cached: the Map reads `effective` every frame.
enum MapLookChoice {
    static let storageKey = "mapLook.v1"
    /// The lineups each Map's picker shows. On the light Map, `.aura` is shown as "Wash" (Aura and Eclipse draw Wash there).
    static let darkLineup: [MapOrbLook] = [.flat, .glass, .aura, .eclipse, .riso, .gradient, .outline]
    static let lightLineup: [MapOrbLook] = [.flat, .glass, .aura, .riso, .gradient, .outline]
    /// The Pro sheet's list: every Pro look once (Wash = the light Map's half of Aura / Eclipse).
    static let proListNames = ["Glass", "Aura", "Eclipse", "Wash", "Riso", "Gradient", "Outline"]

    private static var cached: MapOrbLook = {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? MapOrbLook.flat.rawValue
        let l = MapOrbLook(rawValue: raw) ?? .flat
        return l == .fresnel ? .flat : l   // Fresnel doesn't ship
    }()
    /// What the user picked (kept even when Pro isn't active).
    static var picked: MapOrbLook {
        get { cached }
        set {
            let v = newValue == .fresnel ? .flat : newValue
            cached = v
            UserDefaults.standard.set(v.rawValue, forKey: storageKey)
        }
    }
    #if DEBUG
    /// The still / audit harnesses that set a look at launch (they also unlock Pro: see ProEntitlement).
    static let debugLookHookActive: Bool = ["-MapLookSet", "-MapLookCycle", "-MapOrbRender", "-MapOrbCycle", "-AuraSizeScript"]
        .contains { ProcessInfo.processInfo.arguments.contains($0) }
    #endif
    /// What the Map draws: the pick when it is free or Pro is unlocked, Flat otherwise.
    static var effective: MapOrbLook { picked == .flat || ProEntitlement.isPro ? picked : .flat }

    /// The picker's name for a look on a Map.
    static func name(_ l: MapOrbLook, light: Bool) -> String { light && l.drawsWashOnLight ? "Wash" : l.label }
    /// Is `l` the selected row on this Map's picker?
    static func isSelected(_ l: MapOrbLook, light: Bool, picked p: MapOrbLook) -> Bool {
        light && l == .aura ? p.drawsWashOnLight : l == p
    }
    /// The pick a row stands for: "Wash" on the light Map keeps Eclipse if that's the dark pick, else Aura.
    static func pick(for l: MapOrbLook, light: Bool, current: MapOrbLook) -> MapOrbLook {
        light && l == .aura ? (current == .eclipse ? .eclipse : .aura) : l
    }
}

/// 1.1-A fix-up (2) — the Dashboard panes' surface. Everyone gets Glass (T's pick); the others come with AirPad Pro, the
/// same way as the Map looks (the pick is kept when Pro isn't active; what draws falls back to Glass).
enum DashboardSurfaceChoice: Int, CaseIterable, Identifiable {
    case thin = 0, glass = 1, clear = 2, panel = 3
    static let storageKey = "dashboard.surface.v1"
    static let free: DashboardSurfaceChoice = .glass
    static let lineup: [DashboardSurfaceChoice] = [.glass, .thin, .clear, .panel]
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .thin: "Frosted"
        case .glass: "Glass"
        case .clear: "Clear glass"
        case .panel: "Solid"
        }
    }
    var isFree: Bool { self == Self.free }
    static func effective(pickedRaw: Int, isPro: Bool) -> DashboardSurfaceChoice {
        let p = DashboardSurfaceChoice(rawValue: pickedRaw) ?? free
        return p.isFree || isPro ? p : free
    }
}

/// 1.1-A fix-up (1) — the "Gravity" Appearance toggle (1.1-B: was "Gravity wells") (on by default): the Map's ground dips under the orbs you can
/// read. Off by itself in Low Power Mode and at thermal ≥ .serious (`MapHeatGuard.stressed`), back by itself when that
/// ends. Zoomed out the wells were already off (no title visible → every weight 0), so that is unchanged.
enum MapWells {
    static let storageKey = "map.gravityWells.v1"
    private static var cached: Bool = UserDefaults.standard.object(forKey: storageKey) == nil
        ? true : UserDefaults.standard.bool(forKey: storageKey)
    /// The user's setting.
    static var userOn: Bool {
        get { cached }
        set { cached = newValue; UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
    /// What the Map draws this frame.
    static var active: Bool { cached && !MapHeatGuard.shared.stressed }
}

/// 1.1-B — a Pro look's strength (T's Subtle / Medium / Strong, Ops/reference/orb-strengths-2026-10-29.json).
enum LookStrength: Int, CaseIterable, Identifiable {
    case subtle = 0, medium = 1, strong = 2
    var id: Int { rawValue }
    var label: String { switch self { case .subtle: "Subtle"; case .medium: "Medium"; case .strong: "Strong" } }
}

/// 1.1-B — the Strength picker beside Map look: one strength per Pro look (each look keeps its own), Medium by default.
/// Pro only: without Pro the Map is Flat, which has no strength.
enum MapLookStrength {
    static let storageKey = "mapLook.strength.v1"   // [look rawValue: LookStrength rawValue]
    /// The looks with T's strengths. Glass has none: the study's Glass is the light-Map Light Glass, not the shipping one.
    static func has(_ l: MapOrbLook) -> Bool { [.aura, .eclipse, .riso, .gradient, .outline].contains(l) }
    private static var cached: [String: Int] = (UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]).compactMapValues {
        ($0 as? NSNumber)?.intValue ?? ($0 as? String).flatMap { Int($0) }   // launch-argument values arrive as strings
    }
    static func picked(_ l: MapOrbLook) -> LookStrength { cached[l.rawValue].flatMap(LookStrength.init(rawValue:)) ?? .medium }
    static func set(_ s: LookStrength, for l: MapOrbLook) {
        cached[l.rawValue] = s.rawValue
        UserDefaults.standard.set(cached, forKey: storageKey)
    }
    /// What the Map draws for look `l`.
    static func effective(_ l: MapOrbLook) -> LookStrength { has(l) && ProEntitlement.isPro ? picked(l) : .medium }
}

/// 1.1-B — the background, editable with Pro per appearance (T's ground study, Ops/reference/ground-values-2026-10-29.json;
/// amended 2026-10-29: a custom background applies to every view in that appearance — the Map, cards, lists and the
/// Dashboard's backdrop; the dots stay the Map's): its colour, an optional two-stop gradient across the screen (colour 2 +
/// angle, as the study draws it) and the Map dots' colour + opacity. Until a Pro user customises an appearance
/// (`custom` false), every view keeps today's ground (the Map #111115 / #FFEEED, the library #1A1A1A / #F4F2ED).
struct MapGroundSide: Codable, Equatable {
    var custom = false      // false = today's per-view grounds (the values below are then only the editor's start)
    var color: String       // "RRGGBB"
    var gradient: Bool
    var color2: String
    var angle: Double       // degrees, 0 = toward the right edge, 90 = toward the top
    var dot: String
    var dotOpacity: Double

    static let darkDefault = MapGroundSide(color: "111115", gradient: false, color2: "1D1D26", angle: 90, dot: "FFFFFF", dotOpacity: 0.809)
    static let lightDefault = MapGroundSide(color: "FFEEED", gradient: false, color2: "FFF8EF", angle: 90, dot: "3B362F", dotOpacity: 0.805)

    init(custom: Bool = false, color: String, gradient: Bool, color2: String, angle: Double, dot: String, dotOpacity: Double) {
        self.custom = custom; self.color = color; self.gradient = gradient; self.color2 = color2; self.angle = angle
        self.dot = dot; self.dotOpacity = dotOpacity
    }

    static func rgb(_ hex: String) -> SIMD3<Float> {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
    }
    var colorRGB: SIMD3<Float> { Self.rgb(color) }
    var color2RGB: SIMD3<Float> { Self.rgb(color2) }
    var dotRGB: SIMD3<Float> { Self.rgb(dot) }
    /// The gradient's direction (unit, y up), the study's (cos a, sin a).
    var direction: SIMD2<Float> { SIMD2(Float(cos(angle * .pi / 180)), Float(sin(angle * .pi / 180))) }
    /// The ground at a point of the screen (pt from the centre, y up) on a viewport `vp` — the study's `groundAt`, the
    /// shader's mix: t = clamp(0.5 + dot(offset, dir) / (|vp.x·dir.x| + |vp.y·dir.y|)).
    func ground(atOffset o: SIMD2<Float>, viewport vp: SIMD2<Float>) -> SIMD3<Float> {
        guard gradient else { return colorRGB }
        let d = direction, ext = max(abs(vp.x * d.x) + abs(vp.y * d.y), 1e-3)
        let t = min(max(0.5 + (o.x * d.x + o.y * d.y) / ext, 0), 1)
        return colorRGB + (color2RGB - colorRGB) * t
    }
    /// One colour for what can't follow the gradient per pixel (the orb shaders' "ground"): its middle.
    var meanRGB: SIMD3<Float> { gradient ? (colorRGB + color2RGB) * 0.5 : colorRGB }
}

enum MapGround {
    static let storageKey = "map.ground.v1"
    struct Stored: Codable, Equatable { var dark: MapGroundSide; var light: MapGroundSide }
    static let defaults = Stored(dark: .darkDefault, light: .lightDefault)

    private static var cached: Stored = {
        #if DEBUG
        // `-MapGroundDebug <base64 of a Stored as JSON>` for stills (base64: a bare `{…}` argument is parsed as a plist).
        if let b = UserDefaults.standard.string(forKey: "MapGroundDebug"), let d = Data(base64Encoded: b),
           let s = try? JSONDecoder().decode(Stored.self, from: d) { return s }
        #endif
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(Stored.self, from: d) else { return defaults }
        return s
    }()
    /// The user's edit (kept even without Pro, like the Map look; drawn only with Pro).
    static var edited: Stored {
        get { cached }
        set {
            cached = newValue
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: storageKey) }
            Observed.shared.version += 1
            NotificationCenter.default.post(name: .mapGroundChanged, object: nil)
        }
    }
    static func edited(light: Bool) -> MapGroundSide { light ? cached.light : cached.dark }
    static func setEdited(_ s: MapGroundSide, light: Bool) {
        var v = cached
        if light { v.light = s } else { v.dark = s }
        edited = v
    }
    static var proActive: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProLocked") { return false }
        #endif
        return ProEntitlement.isPro
    }
    /// The custom background this appearance draws, or nil = today's per-view grounds exactly (no Pro, or not customised).
    static func override(light: Bool) -> MapGroundSide? {
        _ = Observed.shared.version   // SwiftUI bodies that draw the background re-render on an edit
        guard proActive else { return nil }
        let e = edited(light: light)
        return e.custom ? e : nil
    }

    /// Observation hook: views reading `override` depend on this.
    @Observable final class Observed { static let shared = Observed(); var version = 0 }

    // MARK: text on the custom background

    /// The two inks text on the custom background chooses between: the light appearance's ink #232A2E and white.
    static let groundInks = TitleInkRule.Inks(light: SIMD3(1, 1, 1), dark: SIMD3(0x23, 0x2A, 0x2E) / 255)
    /// The background's colours across a view (a 7 × 5 grid over a 440 × 956 pt screen; one colour without a gradient).
    static func samples(_ g: MapGroundSide) -> [SIMD3<Float>] {
        guard g.gradient else { return [g.colorRGB] }
        let vp = SIMD2<Float>(440, 956)
        return TitleInkRule.box(halfWidth: vp.x / 2, halfHeight: vp.y / 2).map { g.ground(atOffset: $0, viewport: vp) }
    }
    /// THE rule for text on the custom background (the orb titles' p80 rule over the background's samples), cached per
    /// edit: nil = no custom background in that appearance (text keeps today's ink).
    static func inkPick(light: Bool, pane: Bool = false) -> TitleInkRule.Pick? {
        guard let g = override(light: light) else { return nil }
        let key = light ? (pane ? 3 : 1) : (pane ? 2 : 0)
        if let c = pickCache[key], c.0 == g { return c.1 }
        let s = samples(g).map { pane ? paneOver($0, light: light) : $0 }
        let p = TitleInkRule.pick(samples: s, inks: groundInks)
        pickCache[key] = (g, p)
        return p
    }
    private static var pickCache: [Int: (MapGroundSide, TitleInkRule.Pick)] = [:]
    /// A see-through Dashboard pane (Glass) over the background, as measured on the Simulator (#808080 → #C3–CB light,
    /// #777777 → #70–80 dark): Light lifts the ground 56% toward white; Dark leaves it about where it is.
    static func paneOver(_ c: SIMD3<Float>, light: Bool) -> SIMD3<Float> { light ? c + (SIMD3(repeating: 1) - c) * 0.56 : c }
    /// A text style's contrast on the custom background: `ink` at `opacity` over the background, at the 80th percentile.
    static func styleContrast(light: Bool, opacity: Float) -> Float? {
        guard let g = override(light: light), let p = inkPick(light: light) else { return nil }
        let s = samples(g)
        let shown = s.map { $0 + (p.ink - $0) * opacity }
        return zip(shown, s).map { TitleInkRule.contrast($0, $1) }.sorted()[max(0, s.count - Int((0.8 * Float(s.count)).rounded(.up)))]
    }
}

/// 1.1-B — where this copy of AirPad came from, read at RUNTIME so one binary (archived in App Store config) can carry
/// TestFlight-only switches: StoreKit's `AppTransaction` environment is `.sandbox` on a TestFlight install, `.production`
/// from the App Store. Read once per launch off the main thread; cached for the next launch's synchronous read. Until it
/// resolves (first launch) the answer is "not TestFlight", so a TF-only switch can only appear late, never wrongly.
/// DEBUG builds count as TestFlight; DEBUG `-InstallChannel appstore|testflight` overrides.
enum InstallChannel {
    static let cacheKey = "install.isTestFlight.v1"
    private static var cached: Bool = {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "InstallChannel") {
        case "appstore": return false
        case "testflight": return true
        default: return true
        }
        #else
        return UserDefaults.standard.bool(forKey: cacheKey)
        #endif
    }()
    static var isTestFlight: Bool { cached }

    /// Call once at launch.
    static func resolve() {
        #if !DEBUG
        Task.detached(priority: .utility) {
            guard let r = try? await AppTransaction.shared, case .verified(let t) = r else { return }
            let tf = t.environment == .sandbox
            await MainActor.run {
                UserDefaults.standard.set(tf, forKey: cacheKey)
                guard tf != cached else { return }
                cached = tf
                NotificationCenter.default.post(name: .installChannelResolved, object: nil)
            }
        }
        #endif
    }
}

/// 1.1-B — the Map ground's SHEEN (T's ground study, variant "wellsSlope"): a soft light across the wells' slopes. T
/// decides on the 1.1-B TestFlight, so it is a TestFlight-only switch: shown and ON by default on TestFlight installs,
/// hidden and OFF from the App Store. It reads the wells' field, so it is off whenever the wells are (Gravity off, Low
/// Power, hot phone).
enum MapSheen {
    static let storageKey = "map.sheen.v1"
    /// T's values (ground-values-2026-10-29.json). `reach` (1.38) only shapes the study's depth / static variants, which
    /// weren't ported, so it isn't here.
    static let amount: Float = 0.06, lightAngleDeg: Float = 253, lightHeightDeg: Float = 62
    static let softness: Float = 0.25, relief: Float = 1.58, colour: Float = 0.63, falloffNearWells: Float = 0.62
    /// The light direction, the study's (cos a · cos e, sin a · cos e, sin e).
    static var light: SIMD3<Float> {
        let a = lightAngleDeg * .pi / 180, e = lightHeightDeg * .pi / 180
        return SIMD3(cos(a) * cos(e), sin(a) * cos(e), sin(e))
    }
    private static var cached: Bool = UserDefaults.standard.object(forKey: storageKey) == nil
        ? true : UserDefaults.standard.bool(forKey: storageKey)
    static var userOn: Bool {
        get { cached }
        set { cached = newValue; UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
    /// What the Map draws: TestFlight only, the switch on, and the wells drawing.
    static var active: Bool { InstallChannel.isTestFlight && userOn && MapWells.active }
}

extension Notification.Name {
    static let mapGroundChanged = Notification.Name("MapGroundChanged")
    static let installChannelResolved = Notification.Name("InstallChannelResolved")
}

/// pro-build — the Pro entitlement as the app last verified it, cached so the Map never flashes Flat → Pro at launch.
/// Written ONLY by `ProStore` from `Transaction.currentEntitlements` / `Transaction.updates` (local, verified by StoreKit).
enum ProEntitlement {
    static let storageKey = "pro.unlocked.v1"
    private static var cached: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProUnlocked") || MapLookChoice.debugLookHookActive { return true }   // `-ProUnlocked YES`, still hooks
        #endif
        return UserDefaults.standard.bool(forKey: storageKey)
    }()
    static var isPro: Bool { cached }
    static func set(_ v: Bool) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProUnlocked") || MapLookChoice.debugLookHookActive { return }
        #endif
        guard v != cached else { return }
        cached = v
        UserDefaults.standard.set(v, forKey: storageKey)
        NotificationCenter.default.post(name: .proEntitlementChanged, object: nil)
    }
}

extension Notification.Name {
    static let proEntitlementChanged = Notification.Name("ProEntitlementChanged")
}

/// pro-build — StoreKit 2, no server: products, purchase, restore, the entitlement and the tip jar.
@MainActor @Observable
final class ProStore {
    static let shared = ProStore()

    static let proID = "com.doctorpresident.airpad.pro"
    static let tipIDs = ["com.doctorpresident.airpad.tip.small", "com.doctorpresident.airpad.tip.medium",
                         "com.doctorpresident.airpad.tip.large"]
    static var allIDs: [String] { [proID] + tipIDs }

    enum LoadState: Equatable { case idle, loading, loaded, failed }
    enum Outcome: Equatable { case purchased, pending, cancelled, failed(String) }

    private(set) var products: [String: Product] = [:]
    private(set) var loadState: LoadState = .idle
    private(set) var isPro: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProLocked") { return false }
        #endif
        return ProEntitlement.isPro
    }()
    /// A purchase in flight (its product id), for the buttons' spinners.
    private(set) var busyID: String?
    /// Ask to Buy: Pro was requested and waits for approval.
    private(set) var proPending = false

    private var updatesTask: Task<Void, Never>?

    private init() {}

    /// At launch: listen for transactions (Ask to Buy approvals, refunds, purchases made elsewhere), finish what a crash
    /// left unfinished, and re-verify the entitlement.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates { await self?.handle(result) }
        }
        Task {
            for await result in Transaction.unfinished { await handle(result) }
            await refreshEntitlement()
        }
    }

    /// The entitlement from `Transaction.currentEntitlements` (verified, not revoked). A revoked / refunded Pro → false.
    func refreshEntitlement() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.proID, t.revocationDate == nil { pro = true }
        }
        setPro(pro)
    }

    private func setPro(_ v: Bool) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProLocked") { isPro = false; return }   // `-ProLocked YES`: the locked rows' stills
        if UserDefaults.standard.bool(forKey: "ProUnlocked") || MapLookChoice.debugLookHookActive { isPro = true; return }   // 1.1-B: Pro stills
        #endif
        isPro = v
        if v { proPending = false }
        ProEntitlement.set(v)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let t) = result else { return }   // unverified: ignore (never unlocks)
        if t.productID == Self.proID { await refreshEntitlement() }
        await t.finish()
    }

    /// Prices come from the App Store (`displayPrice`), never from the app.
    func loadProducts() async {
        if loadState == .loading { return }
        loadState = .loading
        do {
            let list = try await Product.products(for: Self.allIDs)
            products = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            loadState = products[Self.proID] == nil ? .failed : .loaded
            #if DEBUG || TESTFLIGHT
            NSLog("[ProStore] products=%d %@", list.count, loadState == .loaded ? "loaded" : "failed (no Pro product)")
            #endif
        } catch {
            loadState = .failed
            #if DEBUG || TESTFLIGHT
            NSLog("[ProStore] products failed: %@", String(describing: error))
            #endif
        }
    }

    func price(_ id: String) -> String? { products[id]?.displayPrice }

    func buy(_ id: String) async -> Outcome {
        guard let product = products[id] else { return .failed("Couldn't reach the App Store. Try again.") }
        busyID = id
        defer { busyID = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let t) = verification else { return .failed("The App Store couldn't verify this purchase.") }
                if t.productID == Self.proID { await refreshEntitlement() }
                await t.finish()
                return .purchased
            case .pending:
                if id == Self.proID { proPending = true }
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            return .failed("Couldn't reach the App Store. Try again.")
        }
    }

    /// Restore Purchases: sync with the App Store, then re-read the entitlement.
    func restore() async -> Bool {
        busyID = "restore"
        defer { busyID = nil }
        do { try await AppStore.sync() } catch { await refreshEntitlement(); return false }
        await refreshEntitlement()
        return true
    }
}
