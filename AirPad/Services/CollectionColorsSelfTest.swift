#if DEBUG
import SwiftUI

/// Mac batch E6 — `-CollectionColorsSelfTest` (Sample scratch, iPhone / iPad / Mac): a chosen colour lands in its own
/// file and nowhere else, reloads, merges by key across devices, survives a collections.json rewrite in the older
/// builds' shape, is pruned with its collection, drives the resolver, and a newer colours file is recognised.
@MainActor
enum CollectionColorsSelfTest {
    static func run(store: CorpusStore) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        for _ in 0..<120 where store.collections.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let root = await store.debugLibraryRoot() else { return "FAIL — no library" }
        let colorsURL = root.appendingPathComponent(CollectionColors.fileName)
        let collURL = root.appendingPathComponent("collections.json")
        guard let c1 = store.collections.first(where: { !$0.isSystem }), let c2 = store.collections.last(where: { !$0.isSystem && $0.id != c1.id })
        else { return "FAIL — fewer than two collections" }

        // 1. Pure: hex forms, names, territory keys, the resolver.
        row("hex normalised", CollectionColors.normalized("e8820a") == "#E8820A" && CollectionColors.normalized("#abc") == "#AABBCC"
            && CollectionColors.normalized("nope") == nil)
        row("swatches are named and distinct", Set(CollectionColors.swatches.map(\.hex)).count == CollectionColors.swatches.count
            && CollectionColors.name("#1b59c2") == "Klein" && CollectionColors.name("#123456") == "#123456")
        row("territory key → collection", CollectionColors.collectionID(territoryKey: "col:abc") == "abc"
            && CollectionColors.collectionID(territoryKey: "tag:film") == nil)
        let auto = CollectionDot.color(c1.id, light: true), chosenColor = CollectionDot.color(c1.id, light: true, chosen: "#E8820A")
        row("resolver: chosen wins, else Automatic", chosenColor == Color(uiColor: CollectionColors.uiColor("#E8820A")!)
            && auto == CollectionDot.automatic(c1.id, light: true))

        // 2. The store writes the colour to its own file only.
        let collBefore = try? Data(contentsOf: collURL)
        await store.setCollectionColor(c1.id, hex: "#e8820a")
        await store.setCollectionColor(c2.id, hex: "#1B59C2")
        let file = (try? Data(contentsOf: colorsURL)).flatMap { try? JSONDecoder().decode(CollectionColors.File.self, from: $0) }
        row("saved to collection-colors.json (version 1)", file?.version == 1 && file?.colors[c1.id] == "#E8820A" && file?.colors[c2.id] == "#1B59C2",
            "\(file.map { "\($0.colors.count) colours" } ?? "no file")")
        row("collections.json untouched by a colour", (try? Data(contentsOf: collURL)) == collBefore)
        await store.debugReloadCollectionColors()
        row("reloads from disk", store.collectionColorHex(c1.id) == "#E8820A" && store.collectionColorHex(c2.id) == "#1B59C2")

        // 3. An older build rewrites collections.json its way (id + name only): the colours file is untouched.
        let colorsBefore = try? Data(contentsOf: colorsURL)
        if let old = try? JSONEncoder.airPad.encode(store.collections) { try? old.write(to: collURL, options: .atomic) }
        row("an id+name collections.json rewrite leaves the colours file as is", (try? Data(contentsOf: colorsURL)) == colorsBefore)
        if let collBefore { try? collBefore.write(to: collURL, options: .atomic) }

        // 4. Merge by key (two devices): a colour set on each side is kept; a clear on one side (the other untouched)
        //    clears; both changed → this device's (written now); no base → a union.
        func merge(_ base: [String: String]?, _ mine: [String: String], _ disk: [String: String]) -> [String: String] {
            let out = AggregateMerge.merge3(file: CollectionColors.fileName, base: base.map { ["version": 1, "colors": $0] },
                                            mine: ["version": 1, "colors": mine], disk: ["version": 1, "colors": disk])
            return ((out as? [String: Any])?["colors"] as? [String: String]) ?? [:]
        }
        let b = ["a": "#111111"]
        row("merge: each side's new colour kept", merge(b, ["a": "#111111", "x": "#222222"], ["a": "#111111", "y": "#333333"]) == ["a": "#111111", "x": "#222222", "y": "#333333"])
        row("merge: cleared on one side, untouched on the other → cleared", merge(b, [:], ["a": "#111111"]) == [:])
        row("merge: changed there, untouched here → theirs", merge(b, ["a": "#111111"], ["a": "#444444"]) == ["a": "#444444"])
        row("merge: changed on both → this device's", merge(b, ["a": "#555555"], ["a": "#444444"]) == ["a": "#555555"])
        row("merge: no base → union", merge(nil, ["a": "#555555"], ["z": "#666666"]) == ["a": "#555555", "z": "#666666"])

        // 5. Automatic clears; deleting a collection drops its colour; the guard knows the file's version.
        await store.setCollectionColor(c2.id, hex: nil)
        row("Automatic removes the entry", store.collectionColorHex(c2.id) == nil
            && ((try? Data(contentsOf: colorsURL)).flatMap { try? JSONDecoder().decode(CollectionColors.File.self, from: $0) }?.colors[c2.id] == nil))
        let temp = await store.createCollection(name: "E6 colour test")
        await store.setCollectionColor(temp.id, hex: "#7B2FF7")
        await store.deleteCollection(id: temp.id)
        row("deleting a collection drops its colour", store.collectionColorHex(temp.id) == nil)
        let v2 = try! JSONSerialization.data(withJSONObject: ["version": 2, "colors": [:]])
        row("a newer colours file is recognised (format guard)", LibraryFormatGuard.isNewer(v2, file: CollectionColors.fileName)
            && !LibraryFormatGuard.isNewer(colorsBefore ?? Data(), file: CollectionColors.fileName))
        await store.setCollectionColor(c1.id, hex: nil)

        return "\(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
