import Foundation

/// One curated catalog model as the phone sees it (from the Host's /v1/catalog). `supportsThinking`
/// is the MEASURED capability (Host increment 1) — the SINGLE source for BOTH the sheet's
/// "Can think / No thinking" copy AND the Thinking pill's presence, so they can't disagree.
struct CatalogModel: Identifiable, Sendable, Equatable {
    let tag: String
    let display: String
    let state: String          // installed-loaded | installed-ejected | not-installed
    let sizeBytes: Int64
    let tier: Int
    let capabilities: [String]
    let verified: Bool
    let note: String
    let supportsThinking: Bool
    let thinkingMeasured: Bool
    let capability: String      // copy.capability — the full curated prose the Mac window shows
    let posture: String         // copy.posture — maker · license · caveat
    var id: String { tag }

    var isResident: Bool { state == "installed-loaded" }
    var isInstalled: Bool { state == "installed-loaded" || state == "installed-ejected" }
    /// The one-line "thinking support" statement — reads from `supportsThinking`, and says so
    /// honestly when it's the manifest claim rather than a measured run.
    var thinkingCopy: String {
        thinkingMeasured ? (supportsThinking ? "Can think" : "No thinking")
                         : (supportsThinking ? "Thinking (unverified)" : "No thinking")
    }
}

/// The phone-side model catalog: fetches /v1/catalog and drives load/eject/install on the paired
/// Host (bearer-plaintext over the tunnel — control ops, not conversational content, so NOT
/// E2E-sealed, like /v1/models). Shared @Observable; views read it in `body` (tracked) and refresh
/// it OFF the render path (on sheet-open / pill-appear), never in `body`.
@MainActor
@Observable
final class HostCatalog {
    static let shared = HostCatalog()

    private(set) var models: [CatalogModel] = []
    private(set) var isLoading = false        // a /v1/catalog fetch is in flight
    private(set) var busyTag: String? = nil   // a load/eject/install is in flight on this tag
    private(set) var reachable = true
    /// Whether a Host is paired at all — the picker (pill row + sheet) is a HOST feature; FM/Ollama
    /// keep their plain provider label. Refreshed off-render (Keychain read, never in `body`).
    private(set) var isPaired = false

    /// Cheap off-render pairing check (Keychain) so a view can decide whether to show the picker
    /// without reading the Keychain from `body`. Also primes `isPaired`.
    @discardableResult func refreshPaired() -> Bool {
        isPaired = HostPairing.load() != nil
        return isPaired
    }

    /// LOAD = SELECT: the resident model IS the selection (one at a time).
    var resident: CatalogModel? { models.first(where: { $0.isResident }) }
    var installed: [CatalogModel] { models.filter { $0.isInstalled } }
    var available: [CatalogModel] { models.filter { !$0.isInstalled } }

    /// Pinned browser UA — Cloudflare's edge 403s unusual UAs (measured); kept identical to what
    /// ModelRouter pins on its Host calls.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func authed(_ url: URL, method: String, body: [String: Any]?) -> URLRequest? {
        guard let pairing = HostPairing.load() else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(pairing.authToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Fetch the catalog. Call OFF the render path (on sheet-open / pill-appear).
    func refresh() async {
        isPaired = HostPairing.load() != nil
        guard let url = HostPairing.load()?.catalogURL, let req = authed(url, method: "GET", body: nil) else {
            models = []; reachable = false; return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                reachable = false; return
            }
            reachable = true
            models = Self.parse(data)
        } catch {
            reachable = false
        }
    }

    private static func parse(_ data: Data) -> [CatalogModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["models"] as? [[String: Any]] else { return [] }
        return arr.compactMap { m -> CatalogModel? in
            guard let tag = m["tag"] as? String, !tag.isEmpty else { return nil }
            let copy = m["copy"] as? [String: Any]
            return CatalogModel(
                tag: tag,
                display: m["display"] as? String ?? tag,
                state: m["state"] as? String ?? "not-installed",
                sizeBytes: Int64((m["sizeBytes"] as? Int) ?? 0),
                tier: m["tier"] as? Int ?? 0,
                capabilities: m["capabilities"] as? [String] ?? [],
                verified: m["verified"] as? Bool ?? false,
                note: m["note"] as? String ?? "",
                supportsThinking: m["supportsThinking"] as? Bool ?? false,
                thinkingMeasured: m["thinkingMeasured"] as? Bool ?? false,
                capability: copy?["capability"] as? String ?? "",
                posture: copy?["posture"] as? String ?? ""
            )
        }
    }

    // MARK: - Actions (catalog-ID only; the Host performs the curated action, then we re-read state)

    private func act(_ url: URL?, tag: String) async {
        guard let url, let req = authed(url, method: "POST", body: ["catalogId": tag]) else { return }
        busyTag = tag
        defer { busyTag = nil }
        _ = try? await URLSession.shared.data(for: req) // install streams NDJSON; this awaits completion
        await refresh()
    }

    func load(_ tag: String) async { await act(HostPairing.load()?.loadURL, tag: tag) }
    func eject(_ tag: String) async { await act(HostPairing.load()?.ejectURL, tag: tag) }
    func install(_ tag: String) async { await act(HostPairing.load()?.installURL, tag: tag) }
}
