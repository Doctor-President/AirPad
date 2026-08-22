// HostE2E — the iOS/CryptoKit mirror of the Host's Go `internal/e2e` package.
// It MUST match the Go key schedule byte-for-byte (see airpad-host/internal/e2e/e2e.go
// and docs/e2e-crypto-design.md). Verified by tools/e2e-conformance against the packaged Host.
//
// Scheme (Noise-IK-flavored, PSK-mixed, envelope-carried ephemeral X25519):
//   masterKey/authToken = HKDF(QR secret)
//   es = X25519(phone_eph, host_static)            request FS  (host static pub `hpk` from the QR)
//   ee = X25519(phone_eph, host_eph)               response FS (host_eph from the first response frame)
//   k_req  = HKDF(ikm=es||master,       salt=sid, info="airpad-host/e2e/req/v1")  AES-256-GCM nonce 0
//   k_resp = HKDF(ikm=es||ee||master,   salt=sid, info="airpad-host/e2e/resp/v1") AES-256-GCM nonce=counter
//
// Self-contained: Foundation + CryptoKit only (no app deps) so it compiles into the app
// AND standalone into the conformance client.

import CryptoKit
import Foundation

enum HostE2E {
    // Domain-separation labels — MUST equal the Go constants exactly.
    static let infoMaster = "airpad-host/master/v1"
    static let infoAuth = "airpad-host/auth/v1"
    static let infoReq = "airpad-host/e2e/req/v1"
    static let infoResp = "airpad-host/e2e/resp/v1"

    /// Derive the E2E master key + the bearer auth token from the QR pairing secret.
    /// Go uses HKDF salt=nil, which RFC-5869/Go treat as HashLen (32) zero bytes.
    static func deriveMaster(secret: Data) -> (master: Data, authToken: String) {
        let zeroSalt = Data(count: 32)
        let master = hkdf(ikm: secret, salt: zeroSalt, info: infoMaster)
        let tok = hkdf(ikm: secret, salt: zeroSalt, info: infoAuth)
        return (master, tok.base64EncodedString())
    }

    /// A phone-side session: seals the request, then opens the sealed response frames.
    final class ClientSession {
        private let ephPriv: Curve25519.KeyAgreement.PrivateKey
        private let master: Data
        let sid: Data
        private let es: Data
        private var kResp: SymmetricKey?

        fileprivate init(ephPriv: Curve25519.KeyAgreement.PrivateKey, master: Data, sid: Data, es: Data) {
            self.ephPriv = ephPriv
            self.master = master
            self.sid = sid
            self.es = es
        }

        /// Complete the handshake from the Host ephemeral pub carried in the first response frame.
        func setHostEphemeral(_ b64: String) throws {
            guard let raw = Data(base64Encoded: b64) else { throw E2EError.badInput("host eph b64") }
            let hpub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
            let ee = try rawSharedSecret(ephPriv, hpub)
            kResp = SymmetricKey(data: hkdf(ikm: es + ee + master, salt: sid, info: infoResp))
        }

        /// Open one counter-prefixed sealed response frame → the inner plaintext bytes.
        func openFrame(_ b64: String) throws -> Data {
            guard let key = kResp else { throw E2EError.notReady }
            guard let buf = Data(base64Encoded: b64), buf.count >= 8 + 16 else { throw E2EError.badInput("frame") }
            let counter = beUInt64(buf.prefix(8))
            let payload = buf.suffix(from: buf.startIndex + 8)
            let nonce = nonceFor(counter)
            let tag = payload.suffix(16)
            let ct = payload.prefix(payload.count - 16)
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce),
                                            ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: ad("resp", sid, counter))
        }
    }

    /// The phone→Host request envelope (JSON on the wire).
    struct RequestEnvelope: Codable {
        let e2e: Int
        let sid: String
        let epk: String
        let ct: String
    }

    /// Seal the real OpenAI chat JSON into an envelope + return the session for the response.
    static func sealRequest(master: Data, hostStaticPub: Data, plaintext: Data) throws
        -> (envelope: RequestEnvelope, session: ClientSession)
    {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let hpk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostStaticPub)
        let es = try rawSharedSecret(eph, hpk)
        var sid = Data(count: 16)
        sid.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        let kReq = SymmetricKey(data: hkdf(ikm: es + master, salt: sid, info: infoReq))
        let sealed = try AES.GCM.seal(plaintext, using: kReq,
                                      nonce: try AES.GCM.Nonce(data: Data(count: 12)),
                                      authenticating: ad("req", sid, 0))
        let ct = sealed.ciphertext + sealed.tag // Go's GCM output = ciphertext||tag (nonce implicit-0)

        let env = RequestEnvelope(
            e2e: 1,
            sid: sid.base64EncodedString(),
            epk: eph.publicKey.rawRepresentation.base64EncodedString(),
            ct: ct.base64EncodedString()
        )
        return (env, ClientSession(ephPriv: eph, master: master, sid: sid, es: es))
    }

    /// Forward-secrecy check (mirror of Go KeylessCannotOpen): a keyless observer holding only
    /// the QR-derived master + the public sid (both recoverable from "transcript + QR secret")
    /// must be UNABLE to open a response frame. Returns true when it cannot (FS holds).
    static func keylessCannotOpen(master: Data, sid: Data, frameB64: String) -> Bool {
        let k = SymmetricKey(data: hkdf(ikm: master, salt: sid, info: infoResp)) // es+ee omitted
        guard let buf = Data(base64Encoded: frameB64), buf.count >= 8 + 16 else { return true }
        let counter = beUInt64(buf.prefix(8))
        let payload = buf.suffix(from: buf.startIndex + 8)
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceFor(counter)),
                                            ciphertext: payload.prefix(payload.count - 16),
                                            tag: payload.suffix(16))
            _ = try AES.GCM.open(box, using: k, authenticating: ad("resp", sid, counter))
            return false // opened → FS VIOLATION
        } catch {
            return true // cannot open → FS holds
        }
    }

    // MARK: - primitives

    /// HKDF-SHA256(ikm, salt, info) → 32 bytes, matching Go crypto/hkdf.Key.
    private static func hkdf(ikm: Data, salt: Data, info: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Raw X25519 shared secret bytes (CryptoKit hides them behind SharedSecret; extract via ContiguousBytes).
    private static func rawSharedSecret(_ priv: Curve25519.KeyAgreement.PrivateKey,
                                        _ pub: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ss = try priv.sharedSecretFromKeyAgreement(with: pub)
        return ss.withUnsafeBytes { Data($0) }
    }

    /// AEAD associated data: dir "|" ‖ sid ‖ counter(8B BE) — matches Go ad().
    private static func ad(_ dir: String, _ sid: Data, _ counter: UInt64) -> Data {
        var d = Data((dir + "|").utf8)
        d.append(sid)
        d.append(beBytes(counter))
        return d
    }

    /// 12-byte GCM nonce: 4 zero bytes ‖ counter(8B BE) — matches Go nonceForCounter().
    private static func nonceFor(_ counter: UInt64) -> Data {
        var n = Data(count: 4)
        n.append(beBytes(counter))
        return n
    }

    private static func beBytes(_ v: UInt64) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    private static func beUInt64(_ d: Data) -> UInt64 {
        var v: UInt64 = 0
        for b in d { v = (v << 8) | UInt64(b) }
        return v
    }

    enum E2EError: Error { case badInput(String), notReady }
}
