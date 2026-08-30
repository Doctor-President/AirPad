// HostPairing — the phone's record of a paired Host, decoded from the scanned QR.
// The QR payload (frozen this arc, matches ws-host):
//   { "tunnelURL": "...", "protocolVersion": 1, "s": "<pairing secret>", "hpk": "<host static X25519 pub, b64>" }
// The phone derives the bearer + E2E master from `s` (never stored raw beyond the secret);
// `hpk` gives the request its forward secrecy. Self-contained (Foundation + HostE2E) so it
// unit-tests standalone; Keychain persistence lives in HostPairingStore.swift (app-only).

import Foundation

struct HostPairing: Codable, Equatable {
    let tunnelURL: String
    let protocolVersion: Int
    let secret: String          // "s"
    let hostPublicKeyB64: String // "hpk"

    enum CodingKeys: String, CodingKey {
        case tunnelURL
        case protocolVersion
        case secret = "s"
        case hostPublicKeyB64 = "hpk"
    }

    /// Parse a scanned QR payload. Returns nil on malformed JSON or missing/invalid fields.
    static func parse(_ payload: String) -> HostPairing? {
        guard let data = payload.data(using: .utf8),
              let p = try? JSONDecoder().decode(HostPairing.self, from: data)
        else { return nil }
        // structural validation: usable secret, a real 32-byte host key, an https URL
        guard p.secret.utf8.count >= 16,
              let hpk = Data(base64Encoded: p.hostPublicKeyB64), hpk.count == 32,
              let u = URL(string: p.tunnelURL), u.scheme == "https", u.host != nil
        else { return nil }
        return p
    }

    // Derived (never travel in the QR):
    var master: Data { HostE2E.deriveMaster(secret: Data(secret.utf8)).master }
    var authToken: String { HostE2E.deriveMaster(secret: Data(secret.utf8)).authToken }
    var hostPublicKey: Data? { Data(base64Encoded: hostPublicKeyB64) }

    /// The chat endpoint URL on the tunnel.
    var chatURL: URL? { endpoint("v1/chat/completions") }
    /// The resume endpoint (BUG 36 Pillar 2 — collect a HELD result after a mid-stream drop).
    var resumeURL: URL? { endpoint("v1/chat/resume") }
    /// The filtered model-list endpoint on the tunnel.
    var modelsURL: URL? { endpoint("v1/models") }
    /// The curated catalog endpoint (per-model state/size/capabilities/copy) — the picker's data
    /// source AND, via `state == installed-loaded`, which model is RESIDENT (LOAD = SELECT).
    var catalogURL: URL? { endpoint("v1/catalog") }
    /// Model-management endpoints the picker sheet drives (catalog-ID-only; the Host performs the
    /// curated action). Bearer-authed plaintext over the tunnel, like /v1/models — not E2E-sealed.
    var loadURL: URL? { endpoint("v1/models/load") }
    var ejectURL: URL? { endpoint("v1/models/eject") }
    var installURL: URL? { endpoint("v1/models/install") }
    /// The health endpoint (capability + host key discovery).
    var healthURL: URL? { endpoint("health") }

    /// A short human label for the paired Host (the tunnel host, e.g. "spike.curiousobjects.co").
    var displayHost: String { URL(string: tunnelURL)?.host ?? tunnelURL }

    private func endpoint(_ path: String) -> URL? {
        let base = tunnelURL.hasSuffix("/") ? String(tunnelURL.dropLast()) : tunnelURL
        return URL(string: base + "/" + path)
    }
}
