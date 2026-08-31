import Foundation

/// One curated catalog model as the phone sees it (from the Host's /v1/catalog). Thinking is TWO
/// measured traits, not one: `supportsThinking` = CAN think (Host /api/show), `thinkingToggleable`
/// = can be told NOT to (Host think:false probe). The Thinking PILL gates on the SECOND — a toggle
/// that does nothing (qwen3:30b reasons regardless) is a lie. The sheet's per-model copy reads the
/// honest ladder off both.
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
    let thinkingToggleable: Bool // MEASURED "can be told NOT to think" (think:false honored); pill gates on this
    let toggleMeasured: Bool     // false → toggleability not yet probed (only the RESIDENT model is probed)
    let supportsTools: Bool      // MEASURED tool-use (a real tool round-trip) for the resident model; manifest claim otherwise
    let toolsMeasured: Bool      // false → the manifest's "tools" claim, UNVERIFIED (not yet probed)
    let capability: String      // copy.capability — the full curated prose the Mac window shows
    let posture: String         // copy.posture — maker · license · caveat
    var id: String { tag }

    var isResident: Bool { state == "installed-loaded" }
    var isInstalled: Bool { state == "installed-loaded" || state == "installed-ejected" }
    /// The one-line "thinking support" statement — an HONEST ladder off the two measured traits.
    /// "always on" is the 30B's case: it thinks but the toggle can't stop it, so we never imply the
    /// user controls it. "Can think" is a capable model whose toggle we haven't probed yet (not
    /// resident); the pill still stays hidden until toggleability is confirmed.
    var thinkingCopy: String {
        guard supportsThinking else { return "No thinking" }
        if !thinkingMeasured { return "Thinking (unverified)" }
        if toggleMeasured { return thinkingToggleable ? "Thinking optional" : "Thinking always on" }
        return "Can think"
    }
    /// Tool-use, MEASURED not inherited — the sheet says WHICH (the last claim on this surface made
    /// honest). nil when the model neither claims nor supports tools (don't mention it at all).
    var toolsCopy: String? {
        if toolsMeasured { return supportsTools ? "Tools" : "No tools" }
        return supportsTools ? "Tools (unverified)" : nil // manifest claims tools but not yet probed
    }
}

/// One residency-mode card as the phone sees it (from /v1/residency) — the SAME source the Mac's
/// Memory tab renders. Never a second phone copy of the ruled §3 wording.
struct ResidencyModeCard: Identifiable, Sendable, Equatable {
    let id: String            // always-on | dynamic | manual (the POST value)
    let name: String          // Always ready | Balanced | Hands-on
    let description: String
    let recommended: Bool
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
    private(set) var busyPercent: Int? = nil  // download progress 0–100 while installing busyTag (nil for load/eject)
    private(set) var reachable = true
    /// The Host's OWN refusal for the last catalog action (disk hard-stop 507, bad tag, upstream
    /// down). Surfaced in the sheet so a failed action doesn't just silently revert to its button —
    /// the exact bug T hit: "Download" flashed "Working…" then reverted with no reason. Mirrors the
    /// chat 409 banner: the Host composes the words, the phone shows them verbatim.
    var lastActionError: String? = nil
    /// Residency (§3) — Always ready / Balanced / Hands-on. The mode CARDS + copy come from the Host
    /// (`/v1/residency`), the SAME source the Mac's Memory tab renders — never a second phone copy.
    private(set) var residencyMode: String = ""
    private(set) var residencyCards: [ResidencyModeCard] = []
    private(set) var residencyFine: String = ""
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
                thinkingToggleable: m["thinkingToggleable"] as? Bool ?? false,
                toggleMeasured: m["toggleMeasured"] as? Bool ?? false,
                supportsTools: m["supportsTools"] as? Bool ?? false,
                toolsMeasured: m["toolsMeasured"] as? Bool ?? false,
                capability: copy?["capability"] as? String ?? "",
                posture: copy?["posture"] as? String ?? ""
            )
        }
    }

    // MARK: - Actions (catalog-ID only; the Host performs the curated action, then we re-read state)

    private func act(_ url: URL?, tag: String) async {
        guard let url, let req = authed(url, method: "POST", body: ["catalogId": tag]) else { return }
        busyTag = tag
        lastActionError = nil
        defer { busyTag = nil }
        do {
            // install streams NDJSON, load/eject return JSON; either way data(for:) awaits completion.
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // A non-2xx (507 insufficient_disk, bad tag, upstream down) carries the Host's own
                // actionable message — surface it verbatim instead of silently reverting the button.
                lastActionError = Self.actionError(data) ?? "That didn't work on your Mac. Try again."
            }
        } catch {
            lastActionError = "Couldn't reach your Mac. Try again."
        }
        await refresh()
    }

    /// Parse the Host's `{error:{message, action}}` refusal into one user line — the Host owns the
    /// words (same contract as the chat banner). nil if the body isn't a recognizable error.
    private static func actionError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let message = err["message"] as? String, !message.isEmpty else { return nil }
        return message
    }

    /// The Host's §18 pre-load MAGNITUDE notice (composed once on the Host; the Mac renders the SAME
    /// string). Set when loading a big model; rendered verbatim — never a phone-authored copy.
    /// PRE-LOAD memory notice (the Mac's pattern): ask the Host with `preview:true` → it returns the
    /// §18 magnitude string WITHOUT loading, so the phone can warn BEFORE committing to a ~20s load.
    /// Returns the notice text, or nil (small model / not paired / error). One string, two renderers.
    func previewLoad(_ tag: String) async -> String? {
        guard let url = HostPairing.load()?.loadURL,
              let req = authed(url, method: "POST", body: ["catalogId": tag, "preview": true]) else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notice = json["notice"] as? [String: Any],
              let text = notice["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    func load(_ tag: String) async {
        guard let url = HostPairing.load()?.loadURL, let req = authed(url, method: "POST", body: ["catalogId": tag]) else { return }
        busyTag = tag
        lastActionError = nil
        defer { busyTag = nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastActionError = Self.actionError(data) ?? "That didn't work on your Mac. Try again."
            }
        } catch {
            lastActionError = "Couldn't reach your Mac. Try again."
        }
        await refresh()
    }
    /// Eject SETTLES (seventh-face): the Host's 200 means ACCEPTED — the runner unloads ~1-2s later.
    /// Poll until `/api/ps` (via refresh) shows it gone, bounded, before returning; fail-closed on
    /// timeout with an actionable error. (Single-eject was on the accept path too — same fix.)
    func eject(_ tag: String) async {
        guard let url = HostPairing.load()?.ejectURL, let req = authed(url, method: "POST", body: ["catalogId": tag]) else { return }
        busyTag = tag
        lastActionError = nil
        defer { busyTag = nil }
        _ = try? await URLSession.shared.data(for: req)
        if !(await waitUntilSettled { [weak self] in self?.models.first(where: { $0.tag == tag })?.isResident != true }) {
            lastActionError = "That model is taking a while to eject. Try again in a moment."
        }
    }

    /// Eject EVERY resident model (phone parity with the Mac's "eject all"), SETTLED: fire each eject,
    /// then poll until NONE are resident. Fail-closed on timeout (the two-tap bug was accept-not-settle).
    func ejectAll() async {
        guard let url = HostPairing.load()?.ejectURL else { return }
        lastActionError = nil
        for tag in models.filter({ $0.isResident }).map(\.tag) {
            guard let req = authed(url, method: "POST", body: ["catalogId": tag]) else { continue }
            busyTag = tag
            _ = try? await URLSession.shared.data(for: req)
        }
        if !(await waitUntilSettled { [weak self] in !(self?.models.contains(where: { $0.isResident }) ?? true) }) {
            lastActionError = "Some models are still ejecting. Try again in a moment."
        }
        busyTag = nil
    }

    /// Poll the catalog until `settled()` holds — a mutation's effect caught up (the Host's 200 means
    /// ACCEPTED, not done). Bounded ~5s; returns false on timeout (fail-closed). The one settle idiom
    /// for every phone-initiated eject, matching the Mac panel's settle burst.
    private func waitUntilSettled(_ settled: @escaping () -> Bool) async -> Bool {
        for _ in 0..<12 {
            await refresh()
            if settled() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    // MARK: - Residency (§3) — cards + copy from the Host, the SAME source the Mac renders

    func fetchResidency() async {
        guard let url = HostPairing.load()?.residencyURL, let req = authed(url, method: "GET", body: nil) else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        residencyMode = json["mode"] as? String ?? ""
        residencyFine = json["fine"] as? String ?? ""
        residencyCards = (json["cards"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, let name = c["name"] as? String else { return nil }
            return ResidencyModeCard(id: id, name: name, description: c["description"] as? String ?? "", recommended: c["recommended"] as? Bool ?? false)
        }
    }

    func setResidencyMode(_ mode: String) async {
        guard let url = HostPairing.load()?.residencyURL, let req = authed(url, method: "POST", body: ["mode": mode]) else { return }
        residencyMode = mode // optimistic; the fetch re-confirms
        _ = try? await URLSession.shared.data(for: req)
        await fetchResidency()
    }

    /// Delete an EJECTED model (plain path): POST + surface any Host refusal, then refresh.
    func delete(_ tag: String) async { await act(HostPairing.load()?.deleteURL, tag: tag) }

    /// Attempt to delete a RESIDENT model to elicit the Host's 409 `eject_first` refusal. Returns the
    /// Host's OWN message (shown verbatim as the eject-first confirmation — never phone-invented copy
    /// for a Host refusal). nil if it unexpectedly succeeded (stale residency) or couldn't be sent.
    /// Nothing is deleted on a 409.
    func attemptDelete(_ tag: String) async -> String? {
        guard let url = HostPairing.load()?.deleteURL, let req = authed(url, method: "POST", body: ["catalogId": tag]) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return Self.actionError(data) ?? "This model is loaded. Eject it first, then delete."
            }
            await refresh() // unexpected success (it wasn't actually resident) → it's gone
            return nil
        } catch {
            return "Couldn't reach your Mac. Try again."
        }
    }

    /// Eject-then-delete for a resident model — the ONE-confirmation flow (T-ruled). Ejects, waits for
    /// the Host to SEE it ejected (delete-while-loaded 409s until the runner unloads — the settle
    /// face; a 200 means ACCEPTED, not unloaded), then deletes. Bounded; surfaces refusals.
    func ejectThenDelete(_ tag: String) async {
        guard let ejectURL = HostPairing.load()?.ejectURL,
              let ejectReq = authed(ejectURL, method: "POST", body: ["catalogId": tag]) else { return }
        busyTag = tag
        lastActionError = nil
        defer { busyTag = nil }
        _ = try? await URLSession.shared.data(for: ejectReq)
        for _ in 0..<12 {
            await refresh()
            if models.first(where: { $0.tag == tag })?.isResident != true { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        await performDelete(tag)
    }

    /// The delete POST + error surfacing + refresh, WITHOUT `act` (so ejectThenDelete owns busyTag
    /// across the whole eject→delete sequence).
    private func performDelete(_ tag: String) async {
        guard let url = HostPairing.load()?.deleteURL, let req = authed(url, method: "POST", body: ["catalogId": tag]) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastActionError = Self.actionError(data) ?? "Couldn't delete this model. Try again."
            }
        } catch {
            lastActionError = "Couldn't reach your Mac. Try again."
        }
        await refresh()
    }

    /// Install STREAMS: the Host sends one `{phase, percent}` line per progress tick (it already
    /// sanitizes Ollama's raw pull format). We consume the stream and publish `busyPercent` so the
    /// row shows real progress instead of a frozen "Working…" for a 19 GB download. A non-2xx (e.g.
    /// 507 insufficient_disk) carries the Host's message → surface it, same as `act()`.
    func install(_ tag: String) async {
        guard let url = HostPairing.load()?.installURL,
              let req = authed(url, method: "POST", body: ["catalogId": tag]) else { return }
        busyTag = tag
        busyPercent = 0
        lastActionError = nil
        defer { busyTag = nil; busyPercent = nil }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var data = Data()
                for try await b in bytes { data.append(b) }
                lastActionError = Self.actionError(data) ?? "That didn't work on your Mac. Try again."
                await refresh(); return
            }
            for try await line in bytes.lines {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let pct = obj["percent"] as? Int { busyPercent = pct }
                else if let pct = obj["percent"] as? Double { busyPercent = Int(pct) }
            }
        } catch {
            lastActionError = "Download interrupted. Try again."
        }
        await refresh()
    }
}
