import Foundation
import Observation

/// 1.1-C (C3 / C4) — private entries. An entry flagged Private (`Node.isPrivate`, the entry menu) is HIDDEN, never
/// blurred, everywhere the app lists, counts or reads entries until "Show private" (slide-out menu) is unlocked with
/// Face ID or the passcode: the Map, lists, grid, search, Recents, Priority, Dashboard Activity, collection counts and
/// the Librarian. It hides again when AirPad goes to the background, which is also where the Face ID lock's timeout
/// starts. (AirPad has no Spotlight index, no data widgets and no entity App Intents yet, so those have nothing to
/// hide.) Embeddings are still computed on the phone; every read path filters (`CorpusStore.hidingPrivate`).
///
/// The flag needs a way to unlock: with no passcode on the phone it can't be set (the entry menu says why).
@MainActor @Observable
final class PrivateEntries {
    static let shared: PrivateEntries = {
        #if DEBUG
        if let d = debugShared() { return d }
        #endif
        return PrivateEntries(auth: AppLock.systemAuthenticator)
    }()

    /// Private entries are showing (unlocked this session).
    private(set) var revealed = false
    private(set) var authenticating = false
    /// What the phone can unlock with (cached: LocalAuthentication is an XPC call, never read from `body`).
    private(set) var method: AppLock.Method

    private let auth: AppLock.Authenticator

    init(auth: AppLock.Authenticator) {
        self.auth = auth
        method = auth.method()
    }

    /// The phone has a passcode (and so Face ID or the passcode can unlock private entries).
    var available: Bool { method != .none }
    /// The one line shown where the flag is disabled.
    static let unavailableReason = "Set a passcode on this iPhone to use private entries."

    /// "Show private": asks for Face ID / the passcode. Returns whether private entries are showing.
    @discardableResult
    func reveal() async -> Bool {
        guard !revealed else { return true }
        guard !authenticating else { return false }
        authenticating = true
        defer { authenticating = false }
        let r = await auth.authenticate("Show private entries")
        if r == .success { revealed = true }
        return revealed
    }

    func hide() { if revealed { revealed = false } }

    /// Follows the scene phase (AppLockInstaller): hidden again whenever AirPad leaves the foreground.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background: hide()
        case .active: method = auth.method()
        default: break
        }
    }

    #if DEBUG
    /// `-PrivateStubAuth success|fail|unavailable` (the self-tests / stills without a real Face ID prompt);
    /// `-PrivateRevealed YES` starts revealed.
    static func debugShared() -> PrivateEntries? {
        guard let mode = UserDefaults.standard.string(forKey: "PrivateStubAuth") else { return nil }
        let r: AppLock.AuthResult = mode == "fail" ? .failed : mode == "unavailable" ? .unavailable : .success
        let p = PrivateEntries(auth: .init(method: { r == .unavailable ? .none : .faceID }, authenticate: { _ in r }))
        if UserDefaults.standard.bool(forKey: "PrivateRevealed") { p.revealed = true }
        return p
    }
    /// Self-tests only.
    func debugSetRevealed(_ v: Bool) { revealed = v }
    #endif
}

import SwiftUI
