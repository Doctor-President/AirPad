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
        guard let json = KeychainHelper.load(key: keychainKey) else { return nil }
        return parse(json)
    }

    /// Forget the pairing (unpair / revoke on the phone side).
    static func clear() {
        KeychainHelper.delete(key: keychainKey)
    }
}
