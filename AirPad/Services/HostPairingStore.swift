// HostPairing persistence — Keychain-backed (app-only; uses AirPad's KeychainHelper).
// Kept separate from HostPairing.swift so the pairing/derive core stays standalone-testable.
// The whole pairing (incl. the secret) lives in the Keychain; re-pair overwrites it (rotates
// the secret → old bearer + E2E keys die), matching ws-host's re-pair/revoke story.

import Foundation

extension HostPairing {
    static let keychainKey = "airpadHostPairing"

    /// Persist this pairing (as JSON) to the Keychain.
    func persist() {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(key: Self.keychainKey, value: json)
        Self.setCached(self)   // the pairing just made is the pairing, even if the Keychain write failed
        NotificationCenter.default.post(name: .librarianRouteChanged, object: nil)   // C2c — re-derive who answers
    }

    /// C2c (T ruling 2026-10-09: pairing is durable) — what the phone knows about its Mac. `.unreadable` = the
    /// Keychain refused the read (a locked phone, an XPC hiccup) before any read succeeded: NOT "unpaired" — callers
    /// keep what they last knew.
    enum Read { case paired(HostPairing), unpaired, unreadable }

    /// Load the current pairing, if any.
    static func load() -> HostPairing? {
        if case .paired(let p) = read() { return p }
        return nil
    }

    /// The pairing, read from the Keychain ONCE per launch and then served from memory (`persist` / `clear` keep the
    /// cache current — nothing else writes the item). Was a Keychain read per call: ~86 a session, and any one that
    /// failed made the app look unpaired. A failed read is logged and NOT cached, so the next call tries again.
    static func read() -> Read {
        #if DEBUG
        // `-DebugPersistLANPairing YES` (C2c test) — the LAN pairing was SAVED to the Keychain at launch, so Unpair
        // really removes it; the launch-arg override must not resurrect it.
        if !UserDefaults.standard.bool(forKey: "DebugPersistLANPairing"), let dbg = debugLANHostPairing() { return .paired(dbg) }
        #endif
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let known = cached { return known.map(Read.paired) ?? .unpaired }
        switch KeychainHelper.read(key: keychainKey) {
        case .found(let json):
            let p = parse(json)
            cached = .some(p)
            return p.map(Read.paired) ?? .unpaired
        case .notFound:
            cached = .some(nil)
            return .unpaired
        case .failed(let status):
            NSLog("[Pairing] Keychain read failed (%d) — not treated as unpaired; will retry", status)
            return .unreadable
        }
    }

    private static let cacheLock = NSLock()
    private static var cached: HostPairing?? = nil   // outer nil = not read yet this launch
    private static func setCached(_ p: HostPairing?) {
        cacheLock.lock(); cached = .some(p); cacheLock.unlock()
    }

    #if DEBUG
    /// Brief BU2 — the DEBUG LAN-Host override (T-chosen gauntlet infra). Launch args
    /// `-DebugHostURL http://127.0.0.1:<port> -DebugHostSecret <S> -DebugHostPubKey <b64>` construct a
    /// pairing DIRECTLY, bypassing `parse`'s https/QR requirement, so the eval gauntlet can drive the
    /// app's REAL sealed pipeline (`ModelRouter.streamHost` → sealed E2E → local `airpad-host` →
    /// Ollama) against a locally-run Host — the "real Host, not direct Ollama" the brief demands,
    /// without a cloudflare tunnel. `hpk` comes from the local Host's `GET /health.hostPublicKey`;
    /// `S` is its `HOST_SECRET` (master/bearer derive identically on both sides). Release-inert.
    /// Brief BU2 — force an UNREACHABLE Host for the next send(s), so the gauntlet can test Retry
    /// after a real transport failure (case 5). ★ This cannot be done by writing `DebugHostURL` with
    /// `UserDefaults.set`: a value supplied as a LAUNCH ARGUMENT lives in the **argument domain**,
    /// which OUTRANKS the application domain, so the original URL keeps winning the read and the
    /// "failing" send quietly succeeds (measured: 68 s of real inference on a turn meant to fail).
    static var debugForceUnreachableHost = false

    private static func debugLANHostPairing() -> HostPairing? {
        let d = UserDefaults.standard
        guard var url = d.string(forKey: "DebugHostURL"), !url.isEmpty,
              let secret = d.string(forKey: "DebugHostSecret"), !secret.isEmpty,
              let hpk = d.string(forKey: "DebugHostPubKey"), !hpk.isEmpty else { return nil }
        if debugForceUnreachableHost { url = "http://127.0.0.1:1" } // nothing listens on port 1
        return HostPairing(tunnelURL: url, protocolVersion: 1, secret: secret, hostPublicKeyB64: hpk)
    }
    #endif

    /// Forget the pairing ("Forget this Mac" in Settings, after a confirmation — the ONLY way a pairing ends).
    static func clear() {
        KeychainHelper.delete(key: keychainKey)
        setCached(nil)
        NotificationCenter.default.post(name: .librarianRouteChanged, object: nil)   // C2c — re-derive who answers
    }

    #if DEBUG
    /// C2c test hook — persist the `-DebugHost…` LAN pairing into the Keychain (like a real QR pairing).
    static func debugPersistLANPairingIfRequested() {
        guard UserDefaults.standard.bool(forKey: "DebugPersistLANPairing"), KeychainHelper.load(key: keychainKey) == nil,
              let p = debugLANHostPairing() else { return }
        p.persist()
    }
    #endif
}
