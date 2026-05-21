import Foundation
import WebKit

// Stage 4.6 commit 5 — user-invoked snapshot of a link's visible body
// text. Distinct from `OGMetadataService` (page-summary chrome) and
// from `DocumentExtractionService.HTMLExtractor` (on-disk HTML files
// already captured to the corpus): this service loads a live URL in a
// hidden WKWebView, waits for navigation completion plus a post-finish
// delay so late JS content renders, then evaluates JS to pull
// `document.body.innerText`. The substrate's embedding pipeline reads
// `LinkItem.snapshotText` the same way it reads
// `DocumentItem.extractedText` — both are the "extracted text on every
// collectible" seam from the Stage 4.6 brief.
//
// Architecture parallels `OGMetadataService` and
// `DocumentExtractionService`: actor isolation gives a single coherent
// concurrency domain so non-Sendable types (WKWebView,
// WKNavigationDelegate) never cross task-group boundaries — only the
// Sendable `LinkSnapshot` result does. `NavigationCoordinator` and
// `withTimeout` are duplicated locally per the small-helper precedent
// the other two services already established (each file owns its copy
// so neither depends on the other's internals).

/// Sendable result of a successful snapshot pass. Returned by
/// `LinkSnapshotService.snapshot(url:)` and applied to the target
/// `LinkItem` via `CorpusStore.applyLinkSnapshot`.
struct LinkSnapshot: Sendable {
    var text: String
    var wordCount: Int
    var capturedAt: Date
}

actor LinkSnapshotService {

    /// Lazy-fallback threshold matching the other 4.6 services. The view
    /// layer doesn't currently auto-fire snapshot — the gesture is
    /// user-invoked — but the constant lives here so future "Refresh
    /// stale snapshots" surfaces have a single staleness anchor.
    static let staleness: TimeInterval = 7 * 24 * 60 * 60

    /// Hard timeout for the full pass. Live URLs need more headroom than
    /// `DocumentExtractionService.HTMLExtractor`'s on-disk HTML (10s):
    /// slow networks, redirect chains, and heavy first-paint pages
    /// realistically push past 10s. Anything longer than 15s is almost
    /// certainly hung — the timeout fires and the user can retry.
    private let hardTimeout: TimeInterval = 15

    /// Soft delay after `didFinish` to let late JS content render.
    /// Doubled vs. the on-disk HTML path (0.5s) because a live page's
    /// post-finish JS (analytics, ads, deferred component mounts) tends
    /// to push readable content into the DOM a beat later than a
    /// pre-rendered HTML file on disk.
    private let postFinishDelay: TimeInterval = 1.0

    init() {}

    func snapshot(url: URL) async -> LinkSnapshot? {
        let postFinishDelay = self.postFinishDelay
        do {
            return try await withTimeout(seconds: hardTimeout) {
                return await SnapshotLoader.load(
                    url: url,
                    postFinishDelay: postFinishDelay
                )
            }
        } catch {
            return nil
        }
    }
}

// MARK: - SnapshotLoader (@MainActor — WKWebView is main-thread only)

@MainActor
private enum SnapshotLoader {

    /// Loads `url` into an off-screen `WKWebView`, awaits navigation
    /// completion plus the configured post-finish delay, then evaluates
    /// JS to pull `document.body.innerText`. Returns nil on load failure
    /// or when the page yielded no readable text.
    static func load(url: URL, postFinishDelay: TimeInterval) async -> LinkSnapshot? {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        let frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let webView = WKWebView(frame: frame, configuration: config)

        // Hold a strong reference to the delegate for the duration of
        // the load — WKWebView's `navigationDelegate` property is weak.
        let coordinator = NavigationCoordinator()
        webView.navigationDelegate = coordinator

        webView.load(URLRequest(url: url))

        await coordinator.awaitFinish()
        try? await Task.sleep(nanoseconds: UInt64(postFinishDelay * 1_000_000_000))

        // Two-step unwrap for `evaluateJavaScript`'s `Any?` return —
        // `try?` on an async throwing function that returns `Any?` yields
        // `Any??`, which doesn't cast cleanly inline. Same pattern as
        // `DocumentExtractionService.HTMLExtractor`.
        let bodyAny: Any?
        do { bodyAny = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") }
        catch { bodyAny = nil }
        guard let raw = (bodyAny as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let wordCount = raw.split(whereSeparator: { $0.isWhitespace }).count
        return LinkSnapshot(text: raw, wordCount: wordCount, capturedAt: Date())
    }
}

/// Bridges `WKNavigationDelegate`'s callback-based finish signal into a
/// single `awaitFinish()` async call. Resumes on the first of
/// `didFinish`, `didFail`, or `didFailProvisionalNavigation` so a load
/// failure unblocks the snapshot instead of hanging until the outer
/// hard timeout trips. Duplicated from `DocumentExtractionService` per
/// the small-helper precedent (both files own their own copy so neither
/// depends on the other's internals).
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
}

// MARK: - Timeout helper (duplicated from OGMetadataService /
// DocumentExtractionService per the small-helper precedent)

private enum LinkSnapshotError: Error { case timeout }

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
            throw LinkSnapshotError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw LinkSnapshotError.timeout
        }
        return first
    }
}
