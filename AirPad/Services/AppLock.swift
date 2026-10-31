import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// 1.1-A (A6, T confirmed) — "Require Face ID". Off by default; Settings → Privacy. When on, AirPad locks at launch and
/// after it has been away for the chosen time (Immediately / 1 min / 5 min, default 1 min), and unlocks with Face ID /
/// Touch ID or the phone's passcode (`.deviceOwnerAuthentication` falls back to the passcode by itself). While the lock
/// is on and AirPad isn't in front, a privacy cover hides it in the app switcher. The cover and the lock screen live in
/// their own window above every view, sheet and the Librarian (`AppLockWindow`).
///
/// Add-only while locked: the share extension only ever writes to the inbox (it shows "Saved!", never an entry), and the
/// Quick Capture control opens a blank capture over the lock screen (`LockedCaptureView`) that saves a new entry and
/// shows nothing that is already in the library.
///
/// Pure state machine: the clock and the authenticator are injected, so `-AppLockSelfTest` drives lock / unlock /
/// timeout / fallback headlessly in the Simulator.
@MainActor @Observable
final class AppLock {
    static let shared: AppLock = {
        #if DEBUG
        if let d = debugShared() { return d }
        #endif
        return AppLock()
    }()

    enum After: Int, CaseIterable, Identifiable {
        case immediately = 0, oneMinute = 60, fiveMinutes = 300
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .immediately: return "Immediately"
            case .oneMinute:   return "After 1 minute"
            case .fiveMinutes: return "After 5 minutes"
            }
        }
    }

    /// What the phone can unlock with. `.none` = no passcode set, so the lock can't apply.
    enum Method: Equatable { case faceID, touchID, opticID, passcode, none }

    enum AuthResult: Equatable { case success, failed, unavailable }

    struct Authenticator {
        var method: () -> Method
        var authenticate: (_ reason: String) async -> AuthResult
    }

    static let enabledKey = "privacy.requireFaceID"
    static let afterKey = "privacy.lockAfter"

    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private let auth: Authenticator

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey); if !enabled { isLocked = false }
            if defaults == .standard { ShareShared.requireFaceID = enabled }   // 1.1-C (C1) — the share sheet reads it
        }
    }
    var after: After { didSet { defaults.set(after.rawValue, forKey: Self.afterKey) } }
    /// The lock screen is up (content hidden until an unlock succeeds).
    private(set) var isLocked: Bool
    /// AirPad isn't in front while the lock is on: the app-switcher cover is up.
    private(set) var coverShown = false
    private(set) var authenticating = false
    /// Quick Capture over the lock screen (add-only).
    var lockedCaptureOpen = false
    /// When AirPad last went to the background (monotonic seconds, counting sleep).
    private var awaySince: TimeInterval?

    init(defaults: UserDefaults = .standard, now: @escaping () -> TimeInterval = AppLock.monotonicNow,
         auth: Authenticator = AppLock.systemAuthenticator) {
        self.defaults = defaults
        self.now = now
        self.auth = auth
        let on = defaults.bool(forKey: Self.enabledKey)
        enabled = on
        after = After(rawValue: defaults.object(forKey: Self.afterKey) as? Int ?? After.oneMinute.rawValue) ?? .oneMinute
        isLocked = on   // a cold launch with the lock on starts locked
        method = auth.method()
        if defaults == .standard { ShareShared.requireFaceID = on }
    }

    /// The overlay window shows while locked or covered.
    var overlayVisible: Bool { enabled && (isLocked || coverShown) }

    /// Cached (LocalAuthentication's check is an XPC call — never from `body`): read at init and on every return to
    /// the foreground (Face ID can be enrolled or the passcode removed meanwhile).
    private(set) var method: Method = .faceID

    /// "Require Face ID" / "Require Touch ID" / "Require Passcode".
    var requireLabel: String {
        switch method {
        case .faceID, .none: return "Require Face ID"
        case .touchID:       return "Require Touch ID"
        case .opticID:       return "Require Optic ID"
        case .passcode:      return "Require Passcode"
        }
    }
    var unlockLabel: String {
        switch method {
        case .faceID, .none: return "Unlock with Face ID"
        case .touchID:       return "Unlock with Touch ID"
        case .opticID:       return "Unlock with Optic ID"
        case .passcode:      return "Unlock with Passcode"
        }
    }

    // MARK: - Scene phase

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active { method = auth.method() }
        guard enabled else { coverShown = false; awaySince = nil; return }
        switch phase {
        case .active:
            coverShown = false
            if let t = awaySince, now() - t >= Double(after.rawValue) { isLocked = true }
            awaySince = nil
        case .inactive:
            // The Face ID sheet itself makes the scene inactive; that is not "away".
            if !authenticating { coverShown = true }
        case .background:
            coverShown = true
            if awaySince == nil { awaySince = now() }
            if after == .immediately { isLocked = true }
        @unknown default:
            break
        }
    }

    // MARK: - Unlock

    @discardableResult
    func unlock() async -> AuthResult {
        guard isLocked, !authenticating else { return isLocked ? .failed : .success }
        authenticating = true
        defer { authenticating = false }
        let r = await auth.authenticate("Unlock AirPad")
        switch r {
        case .success:     isLocked = false
        case .unavailable: isLocked = false   // the phone has no passcode any more: the lock can't apply, don't lock the user out
        case .failed:      break
        }
        return r
    }

    /// Turning the lock on asks for Face ID / the passcode first, so it can only be switched on by someone who can
    /// unlock it. Returns whether it is on.
    @discardableResult
    func requestEnable() async -> Bool {
        guard !enabled else { return true }
        guard method != .none else { return false }
        authenticating = true
        let r = await auth.authenticate("Turn on the lock for AirPad")
        authenticating = false
        if r == .success { enabled = true; isLocked = false }
        return enabled
    }

    // MARK: - System pieces

    nonisolated static func monotonicNow() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9   // keeps counting while the phone sleeps
    }

    static let systemAuthenticator = Authenticator(
        method: {
            let ctx = LAContext()
            var err: NSError?
            if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
                switch ctx.biometryType {
                case .faceID:  return .faceID
                case .touchID: return .touchID
                case .opticID: return .opticID
                default:       return .passcode
                }
            }
            return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) ? .passcode : .none
        },
        authenticate: { reason in
            let ctx = LAContext()
            var err: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return .unavailable }
            do {
                return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
            } catch {
                return .failed
            }
        }
    )

    #if DEBUG
    /// `-AppLockStubAuth success|fail|unavailable` — the stills / UI harness without a real Face ID prompt.
    static func debugShared() -> AppLock? {
        guard let mode = UserDefaults.standard.string(forKey: "AppLockStubAuth") else { return nil }
        let r: AuthResult = mode == "fail" ? .failed : mode == "unavailable" ? .unavailable : .success
        return AppLock(auth: Authenticator(method: { r == .unavailable ? .none : .faceID }, authenticate: { _ in r }))
    }
    #endif
}

// MARK: - The lock window

/// The lock screen + app-switcher cover in their own window above the app's (windowLevel .alert + 1), so it covers
/// sheets, the Librarian panel and the tuner window alike. Installed once by `AppLockInstaller`.
@MainActor
final class AppLockWindow {
    static let shared = AppLockWindow()
    private var window: UIWindow?

    func install(in scene: UIWindowScene, root: AnyView) {
        guard window == nil else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = true
        window = w
    }

    func setVisible(_ visible: Bool) {
        guard let w = window, w.isHidden == visible else { return }
        #if DEBUG
        NSLog("[AppLock] overlay %@ locked=%d cover=%d", visible ? "shown" : "hidden", AppLock.shared.isLocked, AppLock.shared.coverShown)
        #endif
        w.isHidden = !visible
        if visible { w.makeKeyAndVisible() } else { w.resignKey() }
    }
}

/// Zero-size view in ContentView: installs the lock window with the app's environment and follows the scene phase.
struct AppLockInstaller: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router
    private var lock: AppLock { AppLock.shared }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background(WindowSceneReader { scene in
                AppLockWindow.shared.install(in: scene, root: AnyView(
                    AppLockOverlay()
                        .environment(store)
                        .environment(router)
                        .provideAppBodyFont()   // follows Settings → Appearance → Font live
                ))
                if router.entryMode == .quikCapture, lock.isLocked {   // cold launch from the Quick Capture control
                    lock.lockedCaptureOpen = true
                    router.entryMode = .recents
                }
                AppLockWindow.shared.setVisible(lock.overlayVisible)
                if lock.isLocked, scenePhase == .active, !lock.lockedCaptureOpen { Task { await lock.unlock() } }
            })
            .onChange(of: scenePhase) { _, phase in
                lock.scenePhaseChanged(phase)
                PrivateEntries.shared.scenePhaseChanged(phase)   // 1.1-C (C3) — private entries hide again on background
                if phase == .background { store.writeShareIndex() }   // 1.1-C (C1) — the share sheet's entry list
                AppLockWindow.shared.setVisible(lock.overlayVisible)
                if phase == .active, lock.isLocked, !lock.lockedCaptureOpen { Task { await lock.unlock() } }
            }
            .onChange(of: lock.overlayVisible) { _, v in AppLockWindow.shared.setVisible(v) }
            .onChange(of: lock.isLocked) { _, locked in
                if locked { PrivateEntries.shared.hide() }   // 1.1-C — the lock's timeout hides private entries too
                // Unlocked from inside Quick Capture: carry on into the real Quick Capture.
                guard !locked, lock.lockedCaptureOpen else { return }
                lock.lockedCaptureOpen = false
                router.entryMode = .quikCapture
            }
            .onChange(of: router.entryMode) { _, mode in
                // The Quick Capture control while locked: a blank, add-only capture over the lock screen.
                guard mode == .quikCapture, lock.isLocked else { return }
                lock.lockedCaptureOpen = true
                router.entryMode = .recents
            }
    }
}

/// Hands the hosting window's scene to `onScene` once it is known.
private struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void
    func makeUIView(context: Context) -> UIView { SceneProbe(onScene: onScene) }
    func updateUIView(_ uiView: UIView, context: Context) {}
    private final class SceneProbe: UIView {
        let onScene: (UIWindowScene) -> Void
        init(onScene: @escaping (UIWindowScene) -> Void) { self.onScene = onScene; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let s = window?.windowScene { onScene(s) }
        }
    }
}

#if DEBUG
// MARK: - `-AppLockSelfTest`

extension AppLock {
    /// 1.1-A (A6) — the lock's state machine with a fake clock and a scripted authenticator, on a scratch defaults
    /// suite (the real settings are untouched). Logs `[AppLockSelfTest] PASS|FAIL <case>` and a summary line.
    static func runSelfTest() {
        Task { @MainActor in
            var pass = 0, fail = 0
            func check(_ name: String, _ ok: Bool) {
                if ok { pass += 1 } else { fail += 1 }
                let line = "[AppLockSelfTest] \(ok ? "PASS" : "FAIL") \(name)"
                NSLog("%@", line); print(line)
            }
            final class Box { var t: TimeInterval = 1000; var next: AuthResult = .success; var method: Method = .faceID; var asked = 0 }
            let box = Box()
            @MainActor func make(_ suite: String) -> (AppLock, UserDefaults) {
                let d = UserDefaults(suiteName: suite)!
                return (AppLock(defaults: d, now: { box.t },
                                auth: Authenticator(method: { box.method }, authenticate: { _ in box.asked += 1; return box.next })), d)
            }
            let suite = "AppLockSelfTest.\(UUID().uuidString)"
            UserDefaults().removePersistentDomain(forName: suite)

            // Off by default; nothing locks, nothing covers.
            var (lock, d) = make(suite)
            check("off-by-default", !lock.enabled && !lock.isLocked && !lock.overlayVisible && lock.after == .oneMinute)
            lock.scenePhaseChanged(.background); box.t += 3600; lock.scenePhaseChanged(.active)
            check("off-never-locks", !lock.isLocked && !lock.coverShown)

            // Turning it on asks first: a failed ask leaves it off; a passed ask turns it on, unlocked.
            box.next = .failed
            var on = await lock.requestEnable()
            check("enable-needs-auth (failed ask stays off)", !on && !lock.enabled && box.asked == 1)
            box.next = .success
            on = await lock.requestEnable()
            check("enable-after-auth", on && lock.enabled && !lock.isLocked && d.bool(forKey: enabledKey))

            // Cold launch with the lock on starts locked; a failed unlock stays locked; a passed one opens.
            (lock, d) = make(suite)
            check("cold-launch-locked", lock.isLocked && lock.overlayVisible)
            box.next = .failed
            _ = await lock.unlock()
            check("unlock-failed-stays-locked", lock.isLocked)
            box.next = .success
            _ = await lock.unlock()
            check("unlock-passed-opens", !lock.isLocked && !lock.overlayVisible)

            // App switcher: the cover is up whenever AirPad isn't in front (lock on), down when it's back.
            lock.scenePhaseChanged(.inactive)
            check("cover-on-inactive", lock.coverShown && lock.overlayVisible && !lock.isLocked)
            lock.scenePhaseChanged(.background)
            check("cover-in-background", lock.coverShown)
            box.t += 30; lock.scenePhaseChanged(.active)
            check("timeout-1min: away 30 s stays open", !lock.isLocked && !lock.coverShown)
            lock.scenePhaseChanged(.background); box.t += 60; lock.scenePhaseChanged(.active)
            check("timeout-1min: away 60 s locks", lock.isLocked)
            _ = await lock.unlock()

            // 5 minutes: 299 s open, 300 s locked.
            lock.after = .fiveMinutes
            lock.scenePhaseChanged(.background); box.t += 299; lock.scenePhaseChanged(.active)
            check("timeout-5min: away 299 s stays open", !lock.isLocked)
            lock.scenePhaseChanged(.background); box.t += 300; lock.scenePhaseChanged(.active)
            check("timeout-5min: away 300 s locks", lock.isLocked)
            _ = await lock.unlock()

            // Immediately: locked the moment it goes to the background (the cover shows the logo only).
            lock.after = .immediately
            lock.scenePhaseChanged(.background)
            check("immediately-locks-on-background", lock.isLocked && lock.coverShown)
            box.t += 1; lock.scenePhaseChanged(.active)
            check("immediately-still-locked-on-return", lock.isLocked && !lock.coverShown)
            // Control Center / a notification (inactive only) does not lock, even on Immediately.
            _ = await lock.unlock()
            lock.scenePhaseChanged(.inactive); lock.scenePhaseChanged(.active)
            check("inactive-only-does-not-lock", !lock.isLocked)

            // The setting persists.
            (lock, d) = make(suite)
            check("after-persists", lock.after == .immediately && lock.enabled)
            _ = await lock.unlock()

            // Fallback: Touch ID / passcode-only phones get their own words; a phone with no passcode can't turn it on,
            // and a lock left on after the passcode was removed lets the user in instead of locking them out.
            box.method = .passcode; lock.scenePhaseChanged(.active)
            check("passcode-fallback-label", lock.requireLabel == "Require Passcode" && lock.unlockLabel == "Unlock with Passcode")
            box.method = .touchID; lock.scenePhaseChanged(.active)
            check("touchid-label", lock.requireLabel == "Require Touch ID")
            lock.enabled = false
            box.method = .none; lock.scenePhaseChanged(.active)
            on = await lock.requestEnable()
            check("no-passcode-cannot-enable", !on && !lock.enabled)
            d.set(true, forKey: enabledKey)
            (lock, d) = make(suite)
            box.next = .unavailable
            _ = await lock.unlock()
            check("no-passcode-lets-in", !lock.isLocked)

            // Turning it off drops the lock at once.
            box.method = .faceID; box.next = .success
            lock.after = .immediately
            lock.scenePhaseChanged(.background)
            lock.enabled = false
            check("disable-unlocks", !lock.isLocked && !lock.overlayVisible)

            UserDefaults().removePersistentDomain(forName: suite)
            let summary = "[AppLockSelfTest] done \(pass)/\(pass + fail) passed"
            NSLog("%@", summary); print(summary)
        }
    }
}
#endif
