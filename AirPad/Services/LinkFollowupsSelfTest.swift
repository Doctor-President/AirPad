import Foundation

/// Brief BL — pure, deterministic self-test for the link follow-up logic. Runs headlessly
/// under `-BLLinkSelfTest` (see `CorpusStore` launch-arg dispatch) and NSLogs a PASS/FAIL
/// line. Covers only the parts that don't need the network or Apple Intelligence:
///   • BL3.1 — `cleanTitle` strips a site-name segment from EVERY title source (incl. the
///     LP title), is idempotent on an already-clean title, and never strips a <3-word tail.
///   • BL3.3 — `extractReadable` reads the `<article>`/`<main>` region and drops
///     nav/header/footer chrome, so the derived text begins with the article, not "Skip
///     Navigation …".
///   • BL1 — `CorpusStore.singleLinkItems` lifts a legacy `url` into `linkItems[0]` (so
///     "Save content" is available) and PRESERVES an existing snapshot on re-normalise.
///   • BL2 — `classifyContent(.link)` reads the link's derived `title` + `preview` (the gate
///     INPUT that makes a link-only entry nameable), and a committed capture resolves
///     `.automatic` (Done delegates the name).
/// The live Villanova fetch + the FM naming OUTPUT are device-verified by T — a green
/// self-test is not a device verification.
enum LinkFollowupsSelfTest {

    static func run() -> String {
        var pass = 0, fail = 0
        var failures: [String] = []
        func check(_ name: String, _ cond: Bool) {
            if cond { pass += 1 } else { fail += 1; failures.append(name) }
        }

        let date0 = Date(timeIntervalSince1970: 0)

        // ---- BL3.1 — cleanTitle applies to every source ----
        let lpStyle = "Falvey Library :: The Printed Image: Gustave Doré and Paradise Lost"
        let cleaned = OGMetadataService.cleanTitle(lpStyle, siteName: "Falvey Library") ?? ""
        check("BL3.1 strips site-name prefix", cleaned == "The Printed Image: Gustave Doré and Paradise Lost")
        // Idempotent — an already-clean title (no separator) is unchanged.
        check("BL3.1 idempotent on clean title",
              OGMetadataService.cleanTitle(cleaned, siteName: "Falvey Library") == cleaned)
        // Safety — a <3-word tail is NOT stripped (keeps the raw title).
        check("BL3.1 keeps short title raw",
              OGMetadataService.cleanTitle("Foo | Bar", siteName: "Bar") == "Foo | Bar")

        // ---- BL3.3 — extractReadable is article-first, chrome-dropping ----
        let pageHTML = """
        <html><head><title>Falvey Library :: Exhibit</title></head><body>
        <nav>Skip Navigation Falvey Library VISIT / APPLY / GIVE My Library Account</nav>
        <header>Site header chrome</header>
        <article>For the final 2023 installment of the exhibit, we turn to Gustave Doré's \
        illustrations of Paradise Lost, engraved for the 1866 edition.</article>
        <footer>Footer chrome and copyright links</footer>
        </body></html>
        """
        let readable = WebReadability.extractReadable(from: pageHTML, budget: 2000)
        check("BL3.3 begins with article", readable.hasPrefix("For the final 2023 installment"))
        check("BL3.3 drops nav chrome", !readable.contains("Skip Navigation"))
        check("BL3.3 drops footer chrome", !readable.contains("Footer chrome"))
        // Fallback — no article/main, chrome still dropped, body text kept.
        let bodyOnly = "<body><nav>NAV CHROME LINKS</nav><p>Just the body text, long enough to keep.</p></body>"
        let readable2 = WebReadability.extractReadable(from: bodyOnly, budget: 2000)
        check("BL3.3 fallback keeps body text", readable2.contains("Just the body text"))
        check("BL3.3 fallback drops nav", !readable2.contains("NAV CHROME"))

        // ---- BL1 — singleLinkItems lifts + preserves snapshot ----
        var legacy = NodeItem(id: "item-legacy", type: .link, createdAt: date0,
                              url: "https://example.com/article", title: "host.example.com", preview: nil)
        legacy.ogTitle = "The Printed Image"
        legacy.ogDescription = "A real og description"
        let lifted = CorpusStore.singleLinkItems(for: legacy)
        check("BL1 lifts one linkItem", lifted?.count == 1)
        check("BL1 linkItem reuses item id", lifted?.first?.id == "item-legacy")
        check("BL1 linkItem carries url", lifted?.first?.url == "https://example.com/article")
        check("BL1 linkItem carries og title", lifted?.first?.title == "The Printed Image")

        // Re-normalise must PRESERVE an existing snapshot ("Save content" result).
        var snapped = legacy
        var existing = LinkItem(id: "item-legacy", url: "https://example.com/article",
                                title: "The Printed Image", description: nil, imageFile: nil,
                                siteName: nil, faviconFile: nil, capturedAt: date0)
        existing.snapshotText = "saved body text"
        existing.snapshotWordCount = 3
        existing.snapshotAt = date0
        snapped.linkItems = [existing]
        let renorm = CorpusStore.singleLinkItems(for: snapped)
        check("BL1 preserves snapshot text", renorm?.first?.snapshotText == "saved body text")
        check("BL1 preserves snapshot word count", renorm?.first?.snapshotWordCount == 3)

        // No URL → nothing to lift.
        let noURL = NodeItem(id: "item-nourl", type: .link, createdAt: date0, url: nil, title: nil, preview: nil)
        check("BL1 no-url yields no linkItems", CorpusStore.singleLinkItems(for: noURL) == nil)

        // ---- BL2 — classifyContent reads the link's derived title + preview ----
        var linkItem = NodeItem(id: "l1", type: .link, createdAt: date0,
                                url: "https://example.com/a", title: "The Printed Image",
                                preview: "For the final 2023 installment of the exhibit…")
        linkItem.ogDescription = nil
        var node = Node(id: "n1", createdAt: date0, updatedAt: date0,
                        title: "", summary: "", tags: [])
        node.items = [linkItem]
        let buckets = AIService.classifyContent(from: node)
        let derivedJoined = buckets.derived.joined(separator: " ")
        check("BL2 derived contains link title", derivedJoined.contains("The Printed Image"))
        check("BL2 derived contains link preview", derivedJoined.contains("final 2023 installment"))
        check("BL2 link text is DERIVED not authored", buckets.authored.isEmpty)

        // ---- BL2 (Done delegates) — a committed capture resolves .automatic ----
        check("BL2 committed capture is automatic",
              AuthorshipPosture.resolve(for: .committedCapture, setting: true) == .automatic)

        let total = pass + fail
        if fail == 0 {
            return "PASS (\(pass)/\(total))"
        } else {
            return "FAIL (\(pass)/\(total)) — " + failures.joined(separator: "; ")
        }
    }
}
