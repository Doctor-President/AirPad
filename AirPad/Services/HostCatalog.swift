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
    let recommended: Bool      // the V1 default pick + recommended download (Brief BZ)
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

    /// ★ C4 (T, 2026-10-08) — the name a person reads: the catalog's curated `display`, or, for an
    /// off-manifest install (whose Host display IS the raw tag), a name derived from the tag. Never the
    /// raw tag: "qwen3:4b-instruct-2507-q4_K_M" reads "Qwen3 4B Instruct".
    var friendlyName: String { display != tag ? display : Self.friendlyName(forTag: tag) }

    private static let families: [String: String] = [
        "qwen3": "Qwen3", "qwen3.5": "Qwen3.5", "qwen2.5": "Qwen2.5", "qwen2": "Qwen2",
        "llama3": "Llama 3", "llama3.1": "Llama 3.1", "llama3.2": "Llama 3.2", "llama3.3": "Llama 3.3",
        "deepseek-r1": "DeepSeek-R1", "gemma3": "Gemma 3", "gemma4": "Gemma 4", "phi4": "Phi-4",
        "mistral": "Mistral", "gpt-oss": "gpt-oss",
    ]
    /// Tag → readable name: family mapped (or capitalised), sizes upper-cased ("30b-a3b" → "30B-A3B"),
    /// quantisation / date / `latest` tokens dropped, other words capitalised. hf.co tags use the repo name.
    static func friendlyName(forTag tag: String) -> String {
        var t = tag
        if t.hasPrefix("hf.co/") { t = String(t.split(separator: "/").last ?? Substring(t)) }
        let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
        let family = (parts.first ?? t).split(separator: "/").last.map(String.init) ?? t
        let variant = parts.count > 1 ? parts[1] : ""
        func isQuant(_ w: String) -> Bool {
            w.range(of: #"^(i?q\d.*|f(p)?16|bf16|f32|gguf|qat)$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        func isSize(_ w: String) -> Bool { w.range(of: #"^(\d+(\.\d+)?[bm]|a\d+(\.\d+)?b|e\d+b)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
        var words: [String] = []
        let lower = family.lowercased()
        var rest: [String]
        if let mapped = families[lower] {
            words.append(mapped); rest = []
        } else {
            let toks = family.split(separator: "-").map(String.init)
            if let first = toks.first { words.append(families[first.lowercased()] ?? first.prefix(1).uppercased() + first.dropFirst()) }
            rest = Array(toks.dropFirst())
        }
        rest += variant.split(separator: "-").map(String.init)
        for w in rest where !w.isEmpty {
            let l = w.lowercased()
            if l == "latest" || isQuant(w) || l.range(of: #"^\d{4}$"#, options: .regularExpression) != nil { continue }
            if isSize(w) {
                if l.hasPrefix("a"), let last = words.last, isSize(last) { words[words.count - 1] = last + "-" + w.uppercased() }
                else { words.append(w.uppercased()) }
            } else {
                words.append(l == "it" ? "Instruct" : w.prefix(1).uppercased() + w.dropFirst())
            }
        }
        let name = words.joined(separator: " ")
        return name.isEmpty ? tag : name
    }
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
    /// Brief AL1 — the paired record itself, cached off-render, so a view can read the pairing
    /// STATE + display NAME from ONE observable source instead of a per-view `@State` copy that
    /// a pushed `.navigationDestination` resolves against a stale (nil) snapshot. `displayHost`
    /// is read from here in Settings → Models.
    private(set) var pairing: HostPairing? = nil

    /// Cheap off-render pairing check (Keychain) so a view can decide whether to show the picker
    /// without reading the Keychain from `body`. Also primes `isPaired` + `pairing`.
    @discardableResult func refreshPaired() -> Bool {
        switch HostPairing.read() {
        case .paired(let p): pairing = p; isPaired = true
        case .unpaired:      pairing = nil; isPaired = false
        case .unreadable:    break   // C2c — a failed Keychain read is not "unpaired": keep what we last knew
        }
        refreshRoute()
        return isPaired
    }

    /// C2c / C4b2 (T ruling 2026-10-09: model choice is independent of pairing) — who answers the next ask, cached
    /// off-render from `ModelRouter.active` (the one derivation), so the pill and picker name what routing will use.
    enum Answerer: Equatable { case mac, onDevice, endpoint, none }
    private(set) var answerer: Answerer = .none
    /// Apple Intelligence chosen (or the fallback) and ready: the pill names it.
    var onDevice: Bool { answerer == .onDevice }
    private(set) var onDeviceAvailable: Bool = ModelRouter.onDeviceAvailable
    /// Why Apple Intelligence can't answer yet (shown on its picker row); nil when ready or not supported here.
    private(set) var onDeviceNote: String? = nil
    /// The custom endpoint from Settings → Advanced (nil = none), and the first model it reports (resolved in `refresh`).
    private(set) var endpoint: String? = nil
    private(set) var endpointModel: String? = nil
    /// The custom endpoint answered its last check (or hasn't been checked yet): greyed in the picker when not.
    private(set) var endpointReachable = true
    /// The name the pill and picker give the custom endpoint.
    var endpointName: String { endpointModel ?? "Your server" }

    func refreshRoute() {
        onDeviceAvailable = ModelRouter.onDeviceAvailable
        onDeviceNote = onDeviceAvailable ? nil : ModelRouter.onDeviceUnavailableNote
        endpoint = ModelRouter.configuredEndpoint
        endpointReachable = !ModelRouter.endpointUnreachable
        switch ModelRouter.active {
        case .host:            answerer = .mac
        case .ollama:          answerer = .endpoint
        case .foundationModel: answerer = onDeviceAvailable ? .onDevice : .none
        case .local:           answerer = .none
        }
    }

    /// C4b2 — Apple Intelligence chosen in the model menu, whatever the pairing. Every ask routes there until another
    /// source is picked; the pick persists across launches.
    func useOnDevice() {
        ModelRouter.chosenRoute = .onDevice
        refreshRoute()
    }
    /// C4b2 — the user's own server (the custom endpoint), chosen in the model menu while paired or not.
    func useEndpoint() {
        ModelRouter.chosenRoute = .endpoint
        refreshRoute()
    }
    /// C4b2 — back to the Mac with an already-loaded model (no reload): the pick becomes the Mac model again.
    func useMac(_ tag: String) {
        ModelRouter.userPickedHostModel = tag
        pickedTag = tag
        ModelRouter.chosenRoute = .mac
        refreshRoute()
    }

    /// C2c — "Forget this Mac" (Settings, after its confirmation): the one way a pairing ends. Drops the pairing, the
    /// Mac's cached model list, and a Mac pick (the next ask goes to the server or Apple Intelligence).
    func forgetMac() {
        HostPairing.clear()
        UserDefaults.standard.removeObject(forKey: Self.catalogCacheKey)
        models = []
        if ModelRouter.chosenRoute == .mac { ModelRouter.chosenRoute = nil }
        refreshPaired()
    }

    /// C4b2 — the Mac's last model list, kept so a Mac that's away (or a cold launch away from home) still shows its
    /// models in the picker, greyed, instead of nothing.
    private static let catalogCacheKey = "airpadHostCatalogCache"
    init() {
        if let d = UserDefaults.standard.data(forKey: Self.catalogCacheKey) { models = Self.parse(d) }
    }

    /// LOAD = SELECT: the resident model IS the selection (one at a time).
    var resident: CatalogModel? { models.first(where: { $0.isResident }) }

    /// The user's pick, cached off-render (UserDefaults is read in `refresh`/`load`, never in `body`).
    private(set) var pickedTag: String? = ModelRouter.userPickedHostModel
    /// ★ C4a — the model an ask will NAME, by the SAME derivation routing uses
    /// (`ModelRouter.activeHostModel`). The pill shows this one, with ✓ only when it is resident, so
    /// the pill can never claim a model that the next ask's "not loaded" banner contradicts.
    var active: CatalogModel? {
        guard answerer == .mac else { return nil }   // C4b2 — Apple Intelligence or the server answers, not a Mac model
        let entries = models.map { ModelRouter.HostModelEntry(tag: $0.tag, state: $0.state, tier: $0.tier, recommended: $0.recommended) }
        guard let tag = ModelRouter.activeHostModel(entries, picked: pickedTag).preferred else { return nil }
        return models.first { $0.tag == tag }
    }

    /// C4 — the name every surface shows for `m` (pill, sheet rows, confirmations): its friendly name, plus the
    /// tag's variant when a DERIVED name would collide with another installed model's (an off-manifest
    /// `qwen3:4b-q4_K_M` beside the curated "Qwen3 4B" reads "Qwen3 4B (4b-q4_K_M)"), so two rows never look alike.
    func name(_ m: CatalogModel) -> String {
        #if DEBUG
        // C4 UI check — `-GauntletPillName "<very long name>"` stress-tests the pill row with the real controls.
        if let o = UserDefaults.standard.string(forKey: "GauntletPillName"), !o.isEmpty { return o }
        #endif
        let n = m.friendlyName
        guard m.display == m.tag, models.contains(where: { $0.tag != m.tag && $0.friendlyName == n }) else { return n }
        return "\(n) (\(m.tag.split(separator: ":").last.map(String.init) ?? m.tag))"
    }

    /// C4a — an ASK is loading `tag` (the not-loaded auto-load): narrate it on the pill like a picker load.
    func beginAskLoad(_ tag: String) { busyTag = tag }
    func endAskLoad() async {
        busyTag = nil
        await refresh()
    }
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
        pickedTag = ModelRouter.userPickedHostModel
        refreshPaired()
        Task { await refreshEndpointModel() }   // never holds up the Mac's list behind a server that's away
        guard isPaired else { models = []; reachable = false; return }
        guard let url = pairing?.catalogURL, let req = authed(url, method: "GET", body: nil) else {
            reachable = false; return   // C2c — pairing unreadable right now: keep the last known models
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
            UserDefaults.standard.set(data, forKey: Self.catalogCacheKey)
        } catch {
            reachable = false   // C4b2 — the Mac is away: its last models stay listed, greyed
        }
    }

    /// The custom endpoint's first model id, for its name in the pill and picker ("Your server" when it doesn't answer).
    private func refreshEndpointModel() async {
        guard let e = endpoint, let base = URL(string: e) else { endpointModel = nil; return }
        endpointModel = try? await ModelRouter.firstOllamaModel(base: base)
        // C4b2 (T 2026-10-10) — a server that doesn't answer is greyed, and skipped when nothing is chosen.
        if ModelRouter.endpointUnreachable != (endpointModel == nil) {
            ModelRouter.endpointUnreachable = endpointModel == nil
            refreshRoute()
            NotificationCenter.default.post(name: .librarianRouteChanged, object: nil)
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
                recommended: m["recommended"] as? Bool ?? false,
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
        // ★ Brief BU3 (T's ruling, 2026-09-29) — THE USER'S PICK IS THE DEFAULT MODEL. Every picker
        // "Load" funnels through here, so this is the one place the choice is knowable. Persisted so a
        // COLD Host (restarted, idle-ejected, freshly reinstalled) is asked for the model the user
        // actually chose instead of whatever Ollama happens to list first — which was `llama3.2:latest`,
        // an uncurated dev fixture that answered read-in-full lab questions. No separate "default
        // model" setting in V1: the picker IS the setting.
        let previousPick = ModelRouter.userPickedHostModel   // capture BEFORE overwrite (Brief BZ)
        ModelRouter.userPickedHostModel = tag
        if ModelRouter.chosenRoute != .mac { ModelRouter.chosenRoute = .mac }   // C4b2 — a Mac pick routes back to the Mac
        refreshRoute()
        pickedTag = tag
        busyTag = tag
        lastActionError = nil
        defer { busyTag = nil }
        var loaded = false
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastActionError = Self.actionError(data) ?? "That didn't work on your Mac. Try again."
            } else {
                loaded = true
            }
        } catch {
            lastActionError = "Couldn't reach your Mac. Try again."
        }
        // ★ Brief BZ — the PICK owns the held set. On a real switch, release the PREVIOUS pick so the
        // Host stops keeping the old model resident/held (the field bug: picked 4B, the held set still
        // held 8B and reloaded it on a mode switch). Only after the new model loaded, and only for a
        // genuine change — an eject in Always-ready also UNMARKS the old tag from `held`, so the held
        // set collapses to just the new pick. Fire-and-forget cleanup; the refresh below reflects it.
        if loaded, let previous = previousPick, previous != tag,
           let ejectURL = HostPairing.load()?.ejectURL,
           let ejReq = authed(ejectURL, method: "POST", body: ["catalogId": previous]) {
            _ = try? await URLSession.shared.data(for: ejReq)
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

#if DEBUG
// Brief CA — fakes for the `-PillGallery` screenshot harness (renders ModelPillRow in fixed states
// without a live Host). Same-file so they can set the `private(set) models`.
extension CatalogModel {
    static func galleryFake(tag: String, display: String, toggleable: Bool) -> CatalogModel {
        CatalogModel(
            tag: tag, display: display, state: "installed-loaded", sizeBytes: 0, tier: 8,
            recommended: false, capabilities: ["chat", "thinking"], verified: true, note: "",
            supportsThinking: true, thinkingMeasured: true,
            thinkingToggleable: toggleable, toggleMeasured: true,
            supportsTools: false, toolsMeasured: true, capability: "", posture: ""
        )
    }
}
extension HostCatalog {
    static func galleryFake(resident: CatalogModel) -> HostCatalog {
        let c = HostCatalog()
        c.models = [resident]
        return c
    }
}
#endif

#if DEBUG
/// CH Session 2 (C4 / C4a) — pure self-test (`-ModelPickSelfTest`): the ONE active-model derivation that routing and
/// the pill share, the friendly names, and the name-collision rule. Row 1 is T's field state (2026-10-08); its
/// CONTROL is the pre-fix rule (picks filtered to curated), which must give the wrong answer there.
@MainActor enum ModelPickSelfTest {
    static func run() -> String {
        var fails: [String] = [], ran = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            ran += 1
            if !ok { fails.append("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        typealias E = ModelRouter.HostModelEntry
        let ins = "qwen3:4b-instruct-2507-q4_K_M"
        func e(_ t: String, _ st: String, tier: Int = 0, rec: Bool = false) -> E { E(tag: t, state: st, tier: tier, recommended: rec) }
        // 1. T's field state: Instruct (off-manifest, tier 0) picked + resident; the recommended 4B was ejected by the pick's load.
        let field = [e("qwen3:4b", "installed-ejected", tier: 16, rec: true), e(ins, "installed-loaded")]
        let r1 = ModelRouter.activeHostModel(field, picked: ins)
        check("field: the pick (off-manifest, resident) is what an ask names", r1.preferred == ins, "\(r1)")
        // CONTROL — the pre-fix rule dropped a tier-0 pick and asked for the recommended (ejected) model → the 409.
        let curated = field.filter { $0.tier > 0 }
        let oldPick = curated.first { $0.tag == ins }?.tag
        let oldPreferred = oldPick ?? curated.first { $0.state == "installed-loaded" }?.tag ?? curated.first { $0.recommended }?.tag
        check("control: the old rule names the ejected qwen3:4b here", oldPreferred == "qwen3:4b", "\(oldPreferred ?? "nil")")
        // 2. Pick wins over another resident model (Brief BZ).
        let r2 = ModelRouter.activeHostModel([e("qwen3:4b", "installed-ejected", tier: 16, rec: true), e("qwen3:8b", "installed-loaded", tier: 16)], picked: "qwen3:4b")
        check("pick beats resident", r2.preferred == "qwen3:4b" && r2.resident == "qwen3:8b", "\(r2)")
        // 3. Nothing picked → the resident curated model.
        let r3 = ModelRouter.activeHostModel([e("qwen3:4b", "installed-ejected", tier: 16, rec: true), e("qwen3:8b", "installed-loaded", tier: 16)], picked: nil)
        check("no pick → resident curated", r3.preferred == "qwen3:8b", "\(r3)")
        // 4. A resident UNCURATED fixture never becomes the answerer by fallback.
        let r4 = ModelRouter.activeHostModel([e("qwen3:4b", "installed-ejected", tier: 16, rec: true), e("llama3.2:latest", "installed-loaded")], picked: nil)
        check("resident fixture is not a fallback", r4.preferred == "qwen3:4b" && r4.resident == nil, "\(r4)")
        // 5. A deleted pick falls through.
        let r5 = ModelRouter.activeHostModel([e("qwen3:4b", "installed-loaded", tier: 16, rec: true), e(ins, "not-installed")], picked: ins)
        check("deleted pick falls through", r5.preferred == "qwen3:4b", "\(r5)")
        // 6. Nothing installed → nil.
        check("nothing installed → nil", ModelRouter.activeHostModel([e("qwen3:4b", "not-installed", tier: 16, rec: true)], picked: nil).preferred == nil)

        // Friendly names: never the raw tag.
        let names: [(String, String)] = [
            (ins, "Qwen3 4B Instruct"), ("qwen3:30b-a3b-instruct-2507-q4_K_M", "Qwen3 30B-A3B Instruct"),
            ("qwen3:8b", "Qwen3 8B"), ("llama3.2:latest", "Llama 3.2"), ("deepseek-r1:8b", "DeepSeek-R1 8B"),
            ("hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M", "Qwen3 4B Instruct"), ("gemma3:12b-it-qat", "Gemma 3 12B Instruct"),
        ]
        for (t, want) in names { check("name \(t)", CatalogModel.friendlyName(forTag: t) == want, CatalogModel.friendlyName(forTag: t)) }
        func cm(_ t: String, _ d: String) -> CatalogModel {
            CatalogModel(tag: t, display: d, state: "installed-ejected", sizeBytes: 0, tier: d == t ? 0 : 16, recommended: false,
                         capabilities: [], verified: d != t, note: "", supportsThinking: false, thinkingMeasured: false,
                         thinkingToggleable: false, toggleMeasured: false, supportsTools: false, toolsMeasured: false, capability: "", posture: "")
        }
        // Curated display wins; a derived name that collides with another model's gets the variant.
        let c = HostCatalog.galleryFake(resident: cm("qwen3:4b", "Qwen3 4B"))
        c.debugSetModels([cm("qwen3:4b", "Qwen3 4B"), cm("qwen3:4b-q4_K_M", "qwen3:4b-q4_K_M"), cm(ins, ins)])
        check("curated display kept", c.name(c.models[0]) == "Qwen3 4B", c.name(c.models[0]))
        check("collision disambiguated", c.name(c.models[1]) == "Qwen3 4B (4b-q4_K_M)", c.name(c.models[1]))
        check("no collision → plain", c.name(c.models[2]) == "Qwen3 4B Instruct", c.name(c.models[2]))
        for m in c.models { check("no raw tag shown for \(m.tag)", c.name(m) != m.tag || !m.tag.contains(":")) }
        return fails.isEmpty ? "PASS \(ran)/\(ran)" : "FAIL \(fails.count)/\(ran)\n" + fails.joined(separator: "\n")
    }
}
extension HostCatalog {
    func debugSetModels(_ m: [CatalogModel]) { models = m }
}
#endif
