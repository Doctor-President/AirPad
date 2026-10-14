import Foundation
import PDFKit
import UIKit
import WebKit
#if DEBUG
import Network   // -DocExtractOfflineSelfTest's loopback listener only
#endif

// Stage 4.6 — extracts visible text + optional metadata from a captured
// document file. The substrate's embedding pipeline reads
// `DocumentItem.extractedText` the same way it reads
// `LinkItem.snapshotText` for snapshotted links — both are the
// "extracted text on every collectible" seam from the Stage 4.6 brief.
//
// Dispatcher by file extension. v1 supports PDF (PDFKit), HTML
// (WKWebView), TXT/MD (String load), RTF (NSAttributedString).
// Unsupported extensions return nil — the entry still renders via Quick
// Look at the C4 surface but contributes no signal to the substrate.
//
// Actor isolation matches `OGMetadataService`: single coherent
// concurrency domain so non-Sendable types (PDFDocument, WKWebView,
// NSAttributedString) never cross task-group boundaries; only the
// Sendable `DocumentExtraction` result does.

/// Sendable result of a document extraction pass. Thumbnail lives at a
/// temp file URL in `FileManager.default.temporaryDirectory`; the caller
/// (`CorpusStore.applyDocumentExtraction`) moves it into the corpus via
/// `iCloudDriveService.saveItemFile` and removes the temp.
struct DocumentExtraction: Sendable {
    var documentTitle: String?
    var extractedText: String?
    var pageCount: Int?
    var wordCount: Int?
    /// Temp file URL holding the thumbnail in its source format
    /// (currently always JPEG). Nil for formats that don't render a
    /// thumbnail (TXT/MD/RTF — the renderer falls back to a generic
    /// icon-with-extension overlay).
    var thumbnailTempURL: URL?
    /// File extension matching `thumbnailTempURL`'s format, e.g. "jpg".
    var thumbnailExtension: String?
}

actor DocumentExtractionService {

    /// Lazy-fallback threshold matching `OGMetadataService.staleness`.
    /// `DocumentEntryBody.extractIfNeeded` re-fires extraction when the
    /// stored `DocumentItem.extractionAttemptedAt` is older than this —
    /// transient failures (iCloud lazy materialization, momentary
    /// timeout) self-heal on the next view after the window elapses;
    /// persistently broken files don't loop forever within the window.
    static let staleness: TimeInterval = 7 * 24 * 60 * 60

    /// Allow-list of file extensions this service has extractors for.
    /// Callers that gate at their own boundary (the migration-driven
    /// kickoff in `CorpusStore.ensureEntrySchema`, the renderer-side
    /// `.task` in `DocumentEntryBody`) consult this to avoid firing
    /// `extract()` for formats that would no-op. `extract()` itself
    /// also returns nil for unknown extensions, so the gate is an
    /// optimization, not a safety check.
    static let supportedExtensions: Set<String> = [
        "pdf", "html", "htm", "txt", "md", "markdown", "rtf"
    ]

    /// Per-format hard timeout. PDF and HTML are the realistic risk
    /// surface — large PDFs (1000+ pages) and JS-heavy HTML can hang.
    /// TXT/MD/RTF are bounded by file size and don't need an aggressive
    /// timeout, but get one for consistency.
    private let hardTimeout: TimeInterval = 10
    /// HTML soft delay after `didFinish` to let late JS content render.
    /// Matches the 500ms suggested by the Phase 1 audit's WKWebView
    /// reliability section. Distinct from the hard timeout.
    private let htmlPostFinishDelay: TimeInterval = 0.5

    init() {}

    func extract(fileURL: URL, fileType: String) async -> DocumentExtraction? {
        let normalized = fileType.lowercased()
        do {
            return try await withTimeout(seconds: hardTimeout) { [htmlPostFinishDelay] in
                switch normalized {
                case "pdf":
                    return await Self.extractPDF(fileURL: fileURL)
                case "html", "htm":
                    return await HTMLExtractor.extract(
                        fileURL: fileURL,
                        postFinishDelay: htmlPostFinishDelay
                    )
                case "txt", "md", "markdown":
                    return Self.extractPlainText(fileURL: fileURL)
                case "rtf":
                    return Self.extractRTF(fileURL: fileURL)
                default:
                    return nil
                }
            }
        } catch {
            return nil
        }
    }

    // MARK: - PDF

    @MainActor
    private static func extractPDF(fileURL: URL) async -> DocumentExtraction? {
        guard let pdf = PDFDocument(url: fileURL) else { return nil }

        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var combined = ""
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            if let s = page.string, !s.isEmpty {
                if !combined.isEmpty { combined.append("\n\n") }
                combined.append(s)
            }
        }
        let extractedText = combined.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let wordCount = extractedText.map { countWords($0) }

        // Page-1 thumbnail. PDFKit's `thumbnail(of:for:)` handles the
        // CGContext flip + white background internally; output is a
        // standard UIImage we JPEG-encode for the sidecar.
        var thumbTemp: URL?
        if let page = pdf.page(at: 0) {
            let pageRect = page.bounds(for: .mediaBox)
            let targetWidth: CGFloat = 600
            let scale = targetWidth / max(pageRect.width, 1)
            let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            if let jpeg = image.jpegData(compressionQuality: 0.7) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("doc-thumb-\(UUID().uuidString).jpg")
                if (try? jpeg.write(to: tmp, options: .atomic)) != nil {
                    thumbTemp = tmp
                }
            }
        }

        return DocumentExtraction(
            documentTitle: title,
            extractedText: extractedText,
            pageCount: pdf.pageCount > 0 ? pdf.pageCount : nil,
            wordCount: wordCount,
            thumbnailTempURL: thumbTemp,
            thumbnailExtension: thumbTemp != nil ? "jpg" : nil
        )
    }

    // MARK: - Plain text (TXT / MD)

    private static func extractPlainText(fileURL: URL) -> DocumentExtraction? {
        let raw: String
        if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
            raw = utf8
        } else if let latin1 = try? String(contentsOf: fileURL, encoding: .isoLatin1) {
            raw = latin1
        } else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return DocumentExtraction(
            documentTitle: nil,
            extractedText: trimmed,
            pageCount: nil,
            wordCount: trimmed.map { countWords($0) },
            thumbnailTempURL: nil,
            thumbnailExtension: nil
        )
    }

    // MARK: - RTF

    private static func extractRTF(fileURL: URL) -> DocumentExtraction? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        guard let attr = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else { return nil }
        let text = attr.string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return DocumentExtraction(
            documentTitle: nil,
            extractedText: text,
            pageCount: nil,
            wordCount: text.map { countWords($0) },
            thumbnailTempURL: nil,
            thumbnailExtension: nil
        )
    }

    // MARK: - Word count

    private static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

// MARK: - HTML extractor (@MainActor — WKWebView is main-thread only)

@MainActor
private enum HTMLExtractor {

    /// Loads `fileURL` into an off-screen `WKWebView`, waits for
    /// navigation completion plus a short post-finish delay, then
    /// evaluates JS to pull `document.title` and
    /// `document.body.innerText`. Takes a viewport snapshot for the
    /// thumbnail; snapshot failure does NOT invalidate text extraction.
    ///
    /// live-11 (3) — the web view makes ZERO network loads: reading a
    /// user's document must never tell a remote server it was opened
    /// (tracking pixels, fonts, refreshes, beacons). Four layers, each
    /// proven by `-DocExtractOfflineSelfTest`:
    /// - a content rule list blocks every load that isn't `file:`
    ///   (img/css/font/script/frame/media/fetch/XHR/WebSocket/beacon/
    ///   preconnect). Fails CLOSED: no compiled list ⇒ no extraction.
    /// - page JavaScript is OFF. WebRTC ICE (STUN/TURN) goes around the
    ///   resource loader, so rules can't stop it; no page JS ⇒ no
    ///   RTCPeerConnection. Our own `evaluateJavaScript` still runs.
    /// - the navigation delegate cancels any non-`file:` navigation
    ///   (meta refresh, link, form) — the document stays on screen.
    /// - non-persistent data store; read access is the file ALONE, not
    ///   its directory (whose siblings are other entries' files).
    static func extract(fileURL: URL, postFinishDelay: TimeInterval) async -> DocumentExtraction? {
        guard let offline = await offlineRuleList() else { return nil }
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(offline)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let webView = WKWebView(frame: frame, configuration: config)

        // Hold a strong reference to the delegate for the duration of
        // the load — WKWebView's `navigationDelegate` property is weak.
        let coordinator = NavigationCoordinator()
        webView.navigationDelegate = coordinator

        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)

        await coordinator.awaitFinish()
        try? await Task.sleep(nanoseconds: UInt64(postFinishDelay * 1_000_000_000))

        // Explicit do-catch around `evaluateJavaScript` — `try?` on an
        // async throwing function returning `Any?` produces `Any??`,
        // which doesn't cast cleanly inline. Unwrapping in two steps
        // keeps the types straight.
        let titleAny: Any?
        do { titleAny = try await webView.evaluateJavaScript("document.title") }
        catch { titleAny = nil }
        let title = (titleAny as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let bodyAny: Any?
        do { bodyAny = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") }
        catch { bodyAny = nil }
        let bodyText = (bodyAny as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let wordCount = bodyText.map { $0.split(whereSeparator: { $0.isWhitespace }).count }

        var thumbTemp: URL?
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.afterScreenUpdates = true
        if let image = try? await webView.takeSnapshot(configuration: snapshotConfig),
           let jpeg = image.jpegData(compressionQuality: 0.7) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("doc-thumb-\(UUID().uuidString).jpg")
            if (try? jpeg.write(to: tmp, options: .atomic)) != nil {
                thumbTemp = tmp
            }
        }

        return DocumentExtraction(
            documentTitle: title,
            extractedText: bodyText,
            pageCount: nil,
            wordCount: wordCount,
            thumbnailTempURL: thumbTemp,
            thumbnailExtension: thumbTemp != nil ? "jpg" : nil
        )
    }

    /// Block everything, then un-block `file:` (WebKit content rules run
    /// in order; `ignore-previous-rules` lifts the block for matches).
    /// Compiled once per launch and cached.
    private static var cachedOfflineRules: WKContentRuleList?
    private static func offlineRuleList() async -> WKContentRuleList? {
        if let cachedOfflineRules { return cachedOfflineRules }
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}}]"#
        let list = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "DocumentExtractionOffline", encodedContentRuleList: rules)
        cachedOfflineRules = list
        return list
    }
}

/// Bridges `WKNavigationDelegate`'s callback-based finish signal into a
/// single `awaitFinish()` async call. Resumes on the first of
/// `didFinish`, `didFail`, or `didFailProvisionalNavigation` so a load
/// failure unblocks the extractor instead of hanging until the outer
/// hard timeout trips.
@MainActor
private final class NavigationCoordinator: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didResume = false

    func awaitFinish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    private func resumeOnce() {
        guard !didResume else { return }
        didResume = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeOnce()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeOnce()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeOnce()
    }

    /// live-11 (3) — only the local document (and `about:` frames) may
    /// navigate; a refresh, link or form aimed off-device is cancelled.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "file" || scheme == "about" ? .allow : .cancel)
    }
}

// MARK: - Timeout helper (duplicated from OGMetadataService — both files
// own their own copy so neither depends on the other's internals)

private enum DocumentExtractionError: Error { case timeout }

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DocumentExtractionError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw DocumentExtractionError.timeout
        }
        return first
    }
}

// MARK: - String helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
// MARK: - `-DocExtractOfflineSelfTest` (live-11 (3))

extension DocumentExtractionService {

    /// `-DocExtractOfflineSelfTest` — synthetic HTML fixtures that each try one remote-load vector, pointed at a
    /// loopback listener this test owns (127.0.0.1, random port, one listener per fixture so every hit is attributed).
    /// Each runs through the REAL `extract(fileURL:fileType:)`; after the last one returns the test settles 2 s, then
    /// asserts: zero loopback connections, the fixture's visible synthetic text still extracted, and no JS probe saw a
    /// request succeed. Never contacts the internet: the only non-loopback URL is TEST-NET `192.0.2.1` (no route).
    static func offlineSelfTest() async -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docextract-offline-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // name → body HTML; `{U}` is that fixture's loopback base URL (http://127.0.0.1:<port>).
        let probe = "<p id=probe></p><script>function mark(s){document.getElementById('probe').textContent+=' '+s}</script>"
        let vectors: [(String, String)] = [
            ("control", ""),
            ("img", #"<img src="{U}/img.png">"#),
            ("img-srcset", #"<img srcset="{U}/a.png 1x, {U}/b.png 2x">"#),
            ("svg-image", #"<svg width="10" height="10"><image href="{U}/svg.png" width="10" height="10"/></svg>"#),
            ("script-src", #"<script src="{U}/s.js"></script>"#),
            ("stylesheet", #"<link rel="stylesheet" href="{U}/s.css">"#),
            ("preconnect", #"<link rel="preconnect" href="{U}">"#),
            ("dns-prefetch", #"<link rel="dns-prefetch" href="{U}">"#),
            ("prefetch", #"<link rel="prefetch" href="{U}/prefetch.html">"#),
            ("preload", #"<link rel="preload" as="image" href="{U}/preload.png">"#),
            ("icon", #"<link rel="icon" href="{U}/favicon.ico">"#),
            ("css-import", #"<style>@import url("{U}/import.css");</style>"#),
            ("css-background", #"<div style="width:10px;height:10px;background:url({U}/bg.png)"></div>"#),
            ("font-face", #"<style>@font-face{font-family:Synth;src:url({U}/f.woff)} body{font-family:Synth}</style>"#),
            ("iframe", #"<iframe src="{U}/frame.html"></iframe>"#),
            ("object", #"<object data="{U}/obj.html" width="10" height="10"></object>"#),
            ("video", #"<video src="{U}/v.mp4" preload="auto" autoplay muted></video>"#),
            ("audio", #"<audio src="{U}/a.mp3" preload="auto" autoplay></audio>"#),
            ("base-href", #"<base href="{U}/"><img src="relative.png">"#),
            ("page-js-off", probe + #"<script>mark('js=ok')</script>"#),
            ("js-fetch", probe + #"<script>fetch('{U}/fetch').then(()=>mark('fetch=ok')).catch(()=>mark('fetch=err'))</script>"#),
            ("js-xhr", probe + #"<script>var x=new XMLHttpRequest();x.onload=()=>mark('xhr=ok');x.onerror=()=>mark('xhr=err');x.open('GET','{U}/xhr');x.send()</script>"#),
            ("js-beacon", probe + #"<script>mark('beacon='+(navigator.sendBeacon('{U}/beacon','x')?'queued':'refused'))</script>"#),
            ("js-websocket", probe + #"<script>var w=new WebSocket('{W}/ws');w.onopen=()=>mark('ws=ok');w.onerror=()=>mark('ws=err')</script>"#),
            ("js-image-object", probe + #"<script>var i=new Image();i.onload=()=>mark('img=ok');i.onerror=()=>mark('img=err');i.src='{U}/jsimg.png'</script>"#),
            ("meta-refresh", #"<meta http-equiv="refresh" content="0;url={U}/refresh">"#),
            ("js-location", #"<script>setTimeout(function(){window.location='{U}/location'},0)</script>"#),
            ("anchor-click", #"<a id="go" href="{U}/anchor">go</a><script>setTimeout(function(){document.getElementById('go').click()},0)</script>"#),
            ("form-autosubmit", #"<form action="{U}/form" method="post"><input name="a" value="synthetic"></form><script>document.forms[0].submit()</script>"#),
            ("window-open", #"<script>window.open('{U}/popup')</script>"#),
            ("https", #"<img src="{S}/tls.png"><img src="https://192.0.2.1/testnet.png">"#),
            ("video-poster", #"<video poster="{U}/poster.png" width="10" height="10"></video>"#),
            ("embed", #"<embed src="{U}/embed.html" width="10" height="10">"#),
            ("input-image", #"<input type="image" src="{U}/input.png">"#),
            ("anchor-ping", ##"<a id="go" href="#here" ping="{U}/ping">go</a><script>setTimeout(function(){document.getElementById('go').click()},0)</script>"##),
            ("js-eventsource", probe + #"<script>var e=new EventSource('{U}/es');e.onopen=()=>mark('es=ok');e.onerror=()=>mark('es=err')</script>"#),
            ("js-dynamic-import", probe + #"<script>import('{U}/m.js').then(()=>mark('import=ok'),()=>mark('import=err'))</script>"#),
            // WebRTC ICE goes around WebKit's resource loader (content rules never see it): STUN over UDP and TURN
            // over TCP, both at this fixture's loopback listeners.
            ("js-webrtc", probe + #"<script>if(typeof RTCPeerConnection==='undefined'){mark('rtc-absent')}else{var pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:{UDP}'},{urls:'turn:127.0.0.1:{TCP}?transport=tcp',username:'synthetic',credential:'synthetic'}]});pc.createDataChannel('x');pc.onicecandidate=function(e){if(e.candidate&&/srflx|relay/.test(e.candidate.candidate))mark('rtc=ok')};pc.createOffer().then(function(o){return pc.setLocalDescription(o)})}</script>"#),
        ]

        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String) {
            rows.append("\(ok ? "PASS" : "FAIL") \(name) — \(detail)"); if !ok { fails += 1 }
        }
        var fixtures: [(name: String, file: URL, counters: [LoopbackCounter])] = []
        for (name, vector) in vectors {
            guard let counter = await LoopbackCounter.start(udp: false),
                  let udp = await LoopbackCounter.start(udp: true)
            else { row(name, false, "loopback listener failed to start"); continue }
            let host = "127.0.0.1:\(counter.port)"
            let body = vector.replacingOccurrences(of: "{U}", with: "http://\(host)")
                .replacingOccurrences(of: "{S}", with: "https://\(host)")
                .replacingOccurrences(of: "{W}", with: "ws://\(host)")
                .replacingOccurrences(of: "{TCP}", with: "\(counter.port)")
                .replacingOccurrences(of: "{UDP}", with: "\(udp.port)")
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>Synthetic \(name)</title></head>
            <body><h1>SYNTH-\(name) visible marker</h1><p>Synthetic fixture text for offline extraction.</p>\(body)</body></html>
            """
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let file = dir.appendingPathComponent("fixture.html")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? html.write(to: file, atomically: true, encoding: .utf8)
            fixtures.append((name, file, [counter, udp]))
        }
        // The production entry point, six fixtures at a time (each its own listener, so concurrency can't blur hits).
        var texts: [String: String] = [:]
        for start in stride(from: 0, to: fixtures.count, by: 6) {
            let batch = fixtures[start..<min(start + 6, fixtures.count)].map { ($0.name, $0.file) }
            await withTaskGroup(of: (String, DocumentExtraction?).self) { group in
                for (name, file) in batch {
                    group.addTask { (name, await DocumentExtractionService().extract(fileURL: file, fileType: "html")) }
                }
                for await (name, result) in group {
                    if let t = result?.thumbnailTempURL { try? FileManager.default.removeItem(at: t) }
                    texts[name] = result?.extractedText
                }
            }
        }
        let runs = fixtures.map { (name: $0.name, counters: $0.counters, text: texts[$0.name]) }
        // Settle ≥ 2 s after the LAST extraction returned — late JS / refresh / media loads land here if they leak.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        var totalHits = 0
        for r in runs {
            let stopped = r.counters.map { $0.stop() }
            let hits = stopped.reduce(0) { $0 + $1.0 }, requests = stopped.flatMap { $0.1 }
            totalHits += hits
            let textOK = r.text?.contains("SYNTH-\(r.name) visible marker") == true
            let jsOK = !(r.text ?? "").contains("=ok")
            let probeNote = (r.text ?? "").components(separatedBy: "\n").last(where: { $0.contains("=") || $0.contains("rtc-") }) ?? ""
            row(r.name, hits == 0 && textOK && jsOK,
                "hits=\(hits)\(requests.isEmpty ? "" : " [" + requests.joined(separator: ", ") + "]") text=\(textOK ? "ok" : "MISSING")"
                + (probeNote.isEmpty ? "" : " probe=\(probeNote.trimmingCharacters(in: .whitespaces))"))
        }
        row("total-loopback-hits-zero", totalHits == 0 && runs.count == vectors.count, "hits=\(totalHits) fixtures=\(runs.count)/\(vectors.count)")
        return "[DocExtractOfflineSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n")
    }
}

/// Loopback-only TCP (or UDP) listener that counts every incoming connection and records the first request line (the
/// attempted path) — the authoritative evidence for the offline self-test. Answers HTTP with an empty 200 so a
/// leaked load COMPLETES (a leaked navigation then visibly wipes the fixture text).
private final class LoopbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var hits = 0
    private var requests: [String] = []
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DocExtractOfflineSelfTest.loopback")
    private let udp: Bool
    private(set) var port: UInt16 = 0

    private init(listener: NWListener, udp: Bool) { self.listener = listener; self.udp = udp }

    static func start(udp: Bool) async -> LoopbackCounter? {
        let params: NWParameters = udp ? .udp : .tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: params) else { return nil }
        let counter = LoopbackCounter(listener: listener, udp: udp)
        listener.newConnectionHandler = { [counter] conn in counter.accept(conn) }
        let ready: Bool = await withCheckedContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if !resumed { resumed = true; cont.resume(returning: true) }
                case .failed, .cancelled: if !resumed { resumed = true; cont.resume(returning: false) }
                default: break
                }
            }
            listener.start(queue: counter.queue)
        }
        guard ready, let port = listener.port?.rawValue else { listener.cancel(); return nil }
        counter.port = port
        return counter
    }

    private func accept(_ conn: NWConnection) {
        lock.lock(); hits += 1; if udp { requests.append("<udp>") }; lock.unlock()
        if udp { conn.cancel(); return }   // a datagram arriving at all is the evidence
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?
                .components(separatedBy: "\r\n").first.flatMap { $0.isEmpty ? nil : $0 } ?? "<non-http>"
            self?.lock.lock(); self?.requests.append(line.count > 60 ? String(line.prefix(60)) : line); self?.lock.unlock()
            let ok = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(ok.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    func stop() -> (Int, [String]) {
        listener.cancel()
        lock.lock(); defer { lock.unlock() }
        return (hits, requests)
    }
}
#endif
