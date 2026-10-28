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
    private(set) var isPro: Bool = ProEntitlement.isPro
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
