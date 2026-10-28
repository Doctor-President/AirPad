import XCTest
import StoreKit
import StoreKitTest
@testable import AirPad

/// pro-build — StoreKit 2 against StoreKit/AirPadPro.storekit (no network): buy Pro, restore on a fresh install, a refund
/// returns the Map to Flat (the pick kept), Ask to Buy unlocks only once approved, each tip. Prices come from the products.
@MainActor
final class ProStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var store: ProStore { ProStore.shared }

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "AirPadPro")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        store.start()
        await store.refreshEntitlement()   // no transactions → not Pro
        MapLookChoice.picked = .flat
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .loaded)
    }

    /// Wait (≤ 10 s) for an async state change delivered through Transaction.updates.
    private func eventually(_ what: String, _ ok: () -> Bool) async {
        for _ in 0..<100 { if ok() { return }; try? await Task.sleep(for: .milliseconds(100)) }
        XCTFail("timed out waiting for: \(what)")
    }

    func testProductsAndPricesComeFromTheStore() {
        XCTAssertEqual(Set(store.products.keys), Set(ProStore.allIDs))
        XCTAssertEqual(store.price(ProStore.proID), store.products[ProStore.proID]?.displayPrice)
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(MapLookChoice.effective, .flat)
    }

    func testBuyProUnlocksTheLooks() async {
        MapLookChoice.picked = .glass
        XCTAssertEqual(MapLookChoice.effective, .flat, "a Pro pick without Pro draws Flat")
        let outcome = await store.buy(ProStore.proID)
        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(ProEntitlement.isPro, "the cached entitlement the Map reads at launch")
        XCTAssertEqual(MapLookChoice.effective, .glass)
    }

    func testRestoreOnAFreshInstall() async {
        _ = await store.buy(ProStore.proID)
        // a fresh install: the cached entitlement is gone; the purchase lives with the Apple Account
        ProEntitlement.set(false)
        XCTAssertFalse(ProEntitlement.isPro)
        let ok = await store.restore()
        XCTAssertTrue(ok)
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(ProEntitlement.isPro)
    }

    func testRefundReturnsTheMapToFlatAndKeepsThePick() async throws {
        _ = await store.buy(ProStore.proID)
        MapLookChoice.picked = .aura
        XCTAssertEqual(MapLookChoice.effective, .aura)
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProStore.proID })
        try session.refundTransaction(identifier: t.identifier)
        // the revocation arrives through Transaction.updates (the app's listener); a launch re-checks the same way
        await eventually("Flat after the refund (updates listener)") { !store.isPro }
        await store.refreshEntitlement()   // what the next launch does
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(ProEntitlement.isPro)
        XCTAssertEqual(MapLookChoice.effective, .flat)
        XCTAssertEqual(MapLookChoice.picked, .aura, "the user's pick is kept")
    }

    func testAskToBuyUnlocksOnlyOnceApproved() async throws {
        session.askToBuyEnabled = true
        let outcome = await store.buy(ProStore.proID)
        XCTAssertEqual(outcome, .pending)
        XCTAssertTrue(store.proPending)
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(ProEntitlement.isPro)
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProStore.proID })
        try session.approveAskToBuyTransaction(identifier: t.identifier)
        await eventually("Pro after the approval") { store.isPro }
        XCTAssertTrue(ProEntitlement.isPro)
        XCTAssertFalse(store.proPending)
    }

    func testEachTipCompletesAndUnlocksNothing() async {
        for id in ProStore.tipIDs {
            let outcome = await store.buy(id)
            XCTAssertEqual(outcome, .purchased, id)
        }
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(ProEntitlement.isPro)
        // consumables are finished: none stays in the entitlements
        var found = false
        for await r in Transaction.currentEntitlements { if case .verified(let t) = r, ProStore.tipIDs.contains(t.productID) { found = true } }
        XCTAssertFalse(found)
    }
}
