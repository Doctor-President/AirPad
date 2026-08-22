// Stage-4 phone-side E2E conformance client. Compiled STANDALONE with the app's real
// HostE2E.swift (swiftc HostE2E.swift main.swift) and run against the packaged Host .app.
// Proves the CryptoKit client interoperates with the Go Host byte-for-byte.
//
// Env: E2E_BASE (http://127.0.0.1:PORT), HOST_SECRET (pairing secret), E2E_MODEL.
// Exit 0 iff all invariants pass.

import CryptoKit
import Foundation

let base = ProcessInfo.processInfo.environment["E2E_BASE"] ?? "http://127.0.0.1:8844"
let secretStr = ProcessInfo.processInfo.environment["HOST_SECRET"] ?? ""
let model = ProcessInfo.processInfo.environment["E2E_MODEL"] ?? "llama3.2:latest"
let sentinel = "IOSE2ESENTINEL-\(UInt32.random(in: 0..<0xFFFFFF))"

var fails = 0
func green(_ inv: String, _ m: String) { print("  [GREEN] \(inv) — \(m)") }
func red(_ inv: String, _ m: String) { print("  [RED]   \(inv) — \(m)"); fails += 1 }
func die(_ m: String) -> Never { FileHandle.standardError.write(Data("FATAL: \(m)\n".utf8)); exit(2) }

guard !secretStr.isEmpty else { die("HOST_SECRET required") }
let secret = Data(secretStr.utf8)
let (master, authToken) = HostE2E.deriveMaster(secret: secret)
let bearer = "Bearer \(authToken)"

// --- helpers: synchronous HTTP over URLSession ---
func get(_ path: String) -> (Int, Data) {
    var req = URLRequest(url: URL(string: base + path)!)
    req.setValue(bearer, forHTTPHeaderField: "Authorization")
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent") // P8 UA pin
    let sem = DispatchSemaphore(value: 0)
    var code = 0; var body = Data()
    URLSession.shared.dataTask(with: req) { d, r, _ in
        code = (r as? HTTPURLResponse)?.statusCode ?? 0; body = d ?? Data(); sem.signal()
    }.resume()
    sem.wait()
    return (code, body)
}

// --- E0: capability + host pubkey ---
let (hc, hb) = get("/health")
guard hc == 200, let health = try? JSONSerialization.jsonObject(with: hb) as? [String: Any] else {
    die("health \(hc)")
}
if health["e2e"] as? String == "required" { green("INV-E0", "Host advertises e2e=required") }
else { red("INV-E0", "e2e=\(health["e2e"] ?? "nil")") }
guard let hpkB64 = health["hostPublicKey"] as? String, let hpk = Data(base64Encoded: hpkB64), hpk.count == 32 else {
    die("no/bad hostPublicKey")
}

// --- seal the request (with a sentinel) ---
let reqJSON = Data("""
{"model":"\(model)","messages":[{"role":"user","content":"Reply with a short greeting. Marker \(sentinel)"}],"stream":true}
""".utf8)
let (env, session): (HostE2E.RequestEnvelope, HostE2E.ClientSession)
do { (env, session) = try HostE2E.sealRequest(master: master, hostStaticPub: hpk, plaintext: reqJSON) }
catch { die("seal: \(error)") }

// --- E1: request envelope carries no plaintext prompt ---
let envData = try! JSONEncoder().encode(env)
if String(data: envData, encoding: .utf8)!.contains(sentinel) { red("INV-E1", "sentinel in envelope") }
else { green("INV-E1", "request envelope is ciphertext") }

// --- POST the envelope, stream the sealed SSE, capture the transcript ---
var post = URLRequest(url: URL(string: base + "/v1/chat/completions")!)
post.httpMethod = "POST"
post.setValue(bearer, forHTTPHeaderField: "Authorization")
post.setValue("application/json", forHTTPHeaderField: "Content-Type")
post.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
post.httpBody = envData

var transcript = Data()
var recovered = Data()
var firstFrame: String? = nil
var frames = 0
var streamErr: String? = nil
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let (bytes, resp) = try await URLSession.shared.bytes(for: post)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { streamErr = "status \(http.statusCode)"; sem.signal(); return }
        for try await line in bytes.lines {
            transcript.append(Data((line + "\n").utf8))
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let epk = obj["epk"] as? String { try session.setHostEphemeral(epk); continue }
            if let ct = obj["ct"] as? String {
                if firstFrame == nil { firstFrame = ct }
                frames += 1
                recovered.append(try session.openFrame(ct))
            }
        }
    } catch { streamErr = "\(error)" }
    sem.signal()
}
sem.wait()
if let e = streamErr { red("INV-E3", "stream error: \(e)") }

// --- E4: response transcript (edge view) is ciphertext ---
if String(data: transcript, encoding: .utf8)?.contains(sentinel) == true { red("INV-E4", "sentinel in transcript") }
else { green("INV-E4", "response transcript is ciphertext (\(frames) sealed frames)") }

// --- E3: keyed round-trip recovers real assistant content ---
let content = extractContent(recovered)
if content.count > 0 { green("INV-E3", "keyed client round-tripped a real answer (\(content.count) chars)") }
else { red("INV-E3", "no assistant content recovered") }

// --- E2/FS: transcript + QR secret alone cannot open a frame ---
if let f = firstFrame {
    if HostE2E.keylessCannotOpen(master: master, sid: session.sid, frameB64: f) {
        green("INV-E2/FS", "transcript + QR secret alone cannot open a frame (forward secrecy holds)")
    } else { red("INV-E2/FS", "FORWARD SECRECY VIOLATION") }
}

print(String(repeating: "-", count: 76))
if fails != 0 { print("iOS E2E CONFORMANCE: \(fails) RED"); exit(1) }
print("iOS E2E CONFORMANCE: ALL GREEN")

func extractContent(_ raw: Data) -> String {
    var out = ""
    for line in (String(data: raw, encoding: .utf8) ?? "").split(separator: "\n") {
        guard line.hasPrefix("data: ") else { continue }
        let p = String(line.dropFirst(6))
        if p == "[DONE]" { break }
        if let obj = try? JSONSerialization.jsonObject(with: Data(p.utf8)) as? [String: Any],
           let choices = obj["choices"] as? [[String: Any]] {
            for c in choices {
                if let delta = c["delta"] as? [String: Any], let s = delta["content"] as? String { out += s }
            }
        }
    }
    return out
}
