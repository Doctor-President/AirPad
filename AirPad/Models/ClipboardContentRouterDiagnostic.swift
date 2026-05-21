import Foundation
import UIKit
import UniformTypeIdentifiers

/// Stage 4.7 — `ClipboardContentRouter` self-test. Permanent diagnostic
/// infrastructure (not throwaway scaffolding): pins the classification
/// contract the Paste Pad and its eventual second consumer
/// (QuikCapture v2) read against. Mirrors `EntryDeletionDiagnostic`'s
/// shape — in-process assertions, no XCTest target, returns a
/// one-line-or-multi-line summary `SubstrateInspectView` surfaces
/// (green on pass, red on FAIL).
///
/// Uses `UIPasteboard.withUniqueName()` for each test so the user's
/// system clipboard is never touched and the iOS 14+ "pasted from"
/// banner is not provoked during a diagnostic run (the banner attaches
/// to `.general`, not named pasteboards). Each test removes its
/// pasteboard at the end via `UIPasteboard.remove(withName:)`.
///
/// Coverage:
///   T1 — empty pasteboard → `.empty`
///   T2 — direct URL (`pasteboard.url`) → `.url`
///   T3 — plain-text https URL string → `.url` (URL precedence over
///        text per brief)
///   T4 — plain text containing a URL embedded in prose (whitespace
///        present) → `.text` (rejection of multi-token strings as URL)
///   T5 — `mailto:` text → `.text` (non-http/https schemes don't
///        promote to `.url`; only web links do)
///   T6 — image via `pasteboard.image` → `.image`
///   T7 — bare plain text → `.text`
///   T8 — URL + text co-present on same item → `.url` (precedence)
///   T9 — multi-item, all URLs (3 items) → `.multi([.url, .url, .url])`
///        in clipboard order
///   T10 — multi-item, mixed types (URL + text + image) → `.multi(...)`
///        in clipboard order with each per-type classification preserved
///   T11 — multi-item with one empty item → single-survivor collapses
///        back to `.url` (the router strips empty items before deciding
///        single-vs-multi)
///
/// Documented mock-construction limitation (not automated):
///   T12/T13 — file (`.file(URL, fileType:)`) and video (`.video(URL)`)
///        classification cannot be exercised via the unique-pasteboard
///        + `pb.items = [[UTType.identifier: URL]]` approach. iOS's
///        items-dict storage doesn't make a URL value conform to the
///        dict-key UTType: querying `values(forPasteboardType:
///        "public.movie", inItemSet:)` against an item dict where
///        `public.movie` maps to a URL returns nil, not the URL. The
///        real-world surface (Files.app drag/drop, third-party share
///        flows) populates the pasteboard via `NSItemProvider`, which
///        sniffs the file extension and registers proper UTType
///        conformance — that path works against the router; the test
///        mock can't reach it without restructuring the router to
///        an async classification shape (deferred-data-load), which
///        would bend production code for a test artifact and was
///        rejected in C1 design. Manual device-verify covers these
///        branches instead — see "Manual device-verify checklist"
///        below.
///
/// Manual device-verify checklist (one-time per release; record results
/// in the C5 close note):
///   - Drag a `.pdf` from Files.app into a third-party app's
///     copy-to-clipboard flow; in AirPad's SubstrateInspectView tap
///     "Run clipboard-router self-tests" with the clipboard primed —
///     no automated assertion, but inspect that `PastePadView`'s label
///     state (when it lands in C2) reads "Paste document here" rather
///     than empty or text. Equivalent direct check: extend the
///     diagnostic to print `ClipboardContentRouter.classify(.general)`
///     when invoked with a primed clipboard.
///   - Same flow with a `.mp4` file from Files.app → label state
///     reads "Paste video here".
@available(iOS 17.0, *)
@MainActor
enum ClipboardContentRouterDiagnostic {

    static func run() async -> String {
        var failures: [String] = []
        var ran = 0
        var cleanup: [UIPasteboard.Name] = []

        // T1 — empty pasteboard.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            let result = ClipboardContentRouter.classify(pb)
            if case .empty = result {} else {
                failures.append("T1: expected .empty, got \(label(result))")
            }
        }

        // T2 — direct URL via the convenience accessor.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.url = URL(string: "https://example.com")!
            let result = ClipboardContentRouter.classify(pb)
            if case .url(let url) = result {
                if url.absoluteString != "https://example.com" {
                    failures.append("T2: URL mismatch \(url.absoluteString)")
                }
            } else {
                failures.append("T2: expected .url, got \(label(result))")
            }
        }

        // T3 — bare https string in `pasteboard.string` (no `.url` set).
        //      The router's URL-in-text coercion fires; result is `.url`,
        //      not `.text`. Pins the "Paste link here" precedence rule.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "https://example.com/path?q=1"
            let result = ClipboardContentRouter.classify(pb)
            if case .url(let url) = result {
                if url.absoluteString != "https://example.com/path?q=1" {
                    failures.append("T3: URL mismatch \(url.absoluteString)")
                }
            } else {
                failures.append("T3: expected .url from text, got \(label(result))")
            }
        }

        // T4 — prose containing a URL stays `.text`. The router rejects
        //      strings with internal whitespace from URL coercion — a
        //      multi-token string is content, not a link.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "check this out https://example.com it's great"
            let result = ClipboardContentRouter.classify(pb)
            if case .text(let s) = result {
                if !s.contains("https://example.com") {
                    failures.append("T4: text payload missing URL: \(s)")
                }
            } else {
                failures.append("T4: expected .text, got \(label(result))")
            }
        }

        // T5 — `mailto:` scheme stays `.text`. Only http/https promote
        //      to `.url`; other URI schemes (tel:, sms:, custom app
        //      schemes) are content, not web links.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "mailto:t@example.com"
            let result = ClipboardContentRouter.classify(pb)
            if case .text = result {} else {
                failures.append("T5: expected .text for mailto:, got \(label(result))")
            }
        }

        // T6 — UIImage via the convenience accessor. iOS stores it under
        //      a `public.image`-conforming type identifier; router path
        //      2 fires.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.image = makeTestImage()
            let result = ClipboardContentRouter.classify(pb)
            if case .image = result {} else {
                failures.append("T6: expected .image, got \(label(result))")
            }
        }

        // T7 — bare plain text.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "hello world"
            let result = ClipboardContentRouter.classify(pb)
            if case .text(let s) = result {
                if s != "hello world" {
                    failures.append("T7: text mismatch \(s)")
                }
            } else {
                failures.append("T7: expected .text, got \(label(result))")
            }
        }

        // T8 — URL + text both set on the same item. URL wins. (Common
        //      shape: Safari copy puts the URL string under both
        //      `public.url` and `public.utf8-plain-text`.)
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.items = [[
                UTType.url.identifier: URL(string: "https://example.com")!,
                UTType.utf8PlainText.identifier: "https://example.com"
            ]]
            let result = ClipboardContentRouter.classify(pb)
            if case .url = result {} else {
                failures.append("T8: expected .url (precedence over text), got \(label(result))")
            }
        }

        // T9 — multi-item, all URLs.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.items = [
                [UTType.url.identifier: URL(string: "https://a.example.com")!],
                [UTType.url.identifier: URL(string: "https://b.example.com")!],
                [UTType.url.identifier: URL(string: "https://c.example.com")!]
            ]
            let result = ClipboardContentRouter.classify(pb)
            if case .multi(let items) = result {
                if items.count != 3 {
                    failures.append("T9: expected 3 items, got \(items.count)")
                }
                for (i, item) in items.enumerated() {
                    if case .url = item {} else {
                        failures.append("T9: item \(i) expected .url, got \(label(item))")
                    }
                }
            } else {
                failures.append("T9: expected .multi, got \(label(result))")
            }
        }

        // T10 — multi-item, mixed (URL + text + image) in clipboard order.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            let img = makeTestImage()
            let imgData = img.pngData() ?? Data()
            pb.items = [
                [UTType.url.identifier: URL(string: "https://example.com")!],
                [UTType.utf8PlainText.identifier: "some note"],
                [UTType.png.identifier: imgData]
            ]
            let result = ClipboardContentRouter.classify(pb)
            if case .multi(let items) = result {
                if items.count != 3 {
                    failures.append("T10: expected 3 items, got \(items.count)")
                } else {
                    if case .url = items[0] {} else {
                        failures.append("T10: item 0 expected .url, got \(label(items[0]))")
                    }
                    if case .text = items[1] {} else {
                        failures.append("T10: item 1 expected .text, got \(label(items[1]))")
                    }
                    if case .image = items[2] {} else {
                        failures.append("T10: item 2 expected .image, got \(label(items[2]))")
                    }
                }
            } else {
                failures.append("T10: expected .multi, got \(label(result))")
            }
        }

        // T11 — multi-item with one empty item collapses to the single
        //       surviving classification (.multi never has count 1).
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.items = [
                [:],
                [UTType.url.identifier: URL(string: "https://example.com")!]
            ]
            let result = ClipboardContentRouter.classify(pb)
            if case .url = result {} else {
                failures.append("T11: expected .url (collapsed survivor), got \(label(result))")
            }
        }

        // T12 / T13 — file and video classification: not automated. See
        // the "Documented mock-construction limitation" block in the
        // file header. Manual device-verify checklist covers these
        // branches against real Files.app sources.

        // Cleanup: drop every uniquely-named pasteboard we created. Any
        // leftover named pasteboard from a crashed mid-run is invisible
        // to `.general` and is reaped by iOS on process exit anyway.
        for name in cleanup {
            UIPasteboard.remove(withName: name)
        }

        if failures.isEmpty {
            return "ClipboardContentRouter: \(ran)/\(ran) passed"
        } else {
            return "ClipboardContentRouter FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Helpers

    private static func makeTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private static func label(_ content: ClipboardContent) -> String {
        switch content {
        case .url: return ".url"
        case .image: return ".image"
        case .video: return ".video"
        case .file: return ".file"
        case .text: return ".text"
        case .multi(let items): return ".multi(\(items.count))"
        case .empty: return ".empty"
        }
    }
}
