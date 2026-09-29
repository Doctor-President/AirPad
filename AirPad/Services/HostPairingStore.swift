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
    }

    /// Load the current pairing, if any.
    static func load() -> HostPairing? {
        #if DEBUG
        if let dbg = debugLANHostPairing() { return dbg }
        #endif
        guard let json = KeychainHelper.load(key: keychainKey) else { return nil }
        return parse(json)
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

    /// Forget the pairing (unpair / revoke on the phone side).
    static func clear() {
        KeychainHelper.delete(key: keychainKey)
    }
}
