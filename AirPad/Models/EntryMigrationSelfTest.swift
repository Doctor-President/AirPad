import Foundation

/// Stage 3.1a — entry-primitive migration self-test. Permanent diagnostic
/// infrastructure (not throwaway scaffolding): T sees the byte-lossless
/// migration claim verified end-to-end on real device builds before commit
/// (b) ships, and the suite stays as regression protection for any future
/// schema change that touches `migrateEntrySchemaIfNeeded`.
///
/// Mirrors the `UMAPSelfTest` / `HDBSCANSelfTest` pattern — in-process
/// assertions, no XCTest target, returns a one-line-or-multi-line summary
/// suitable for inline display in `SubstrateInspectView`.
///
/// Coverage:
///   T1  — empty items array migrates cleanly
///   T2  — single text item gets bare "Text" + isExpanded + updatedAt
///   T3  — duplicates of same type get sequential numbering (Voice, Voice 2)
///   T4  — mixed types count independently (Text, Voice, Image — not "… 2")
///   T5  — all six basic types with duplicates, full coverage
///   T6  — migration is idempotent (second call no-ops, returns false)
///   T7  — every legacy content field preserved byte-equal pre/post
///   T8  — legacy-shape JSON round-trip (decode without new fields, migrate)
///   T9  — already-migrated node (version=1) skipped, no field overwrite
@available(iOS 17.0, *)
@MainActor
enum EntryMigrationSelfTest {

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        // T1 — empty items array migrates cleanly: version bumps to 1, items
        // stays empty, no crash on empty counter map.
        do {
            ran += 1
            var node = makeNode(items: [])
            let didMigrate = migrateEntrySchemaIfNeeded(&node)
            if !didMigrate { failures.append("T1: expected migration, got no-op") }
            if node.entrySchemaVersion != 1 { failures.append("T1: version \(node.entrySchemaVersion) != 1") }
            if !node.items.isEmpty { failures.append("T1: items array mutated") }
        }

        // T2 — single text item: bare "Text" (no ordinal), isExpanded true,
        // updatedAt backfilled to createdAt.
        do {
            ran += 1
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let item = makeItem(id: "t2", type: .text, createdAt: created, content: "hello")
            var node = makeNode(items: [item])
            _ = migrateEntrySchemaIfNeeded(&node)
            let m = node.items[0]
            if m.displayName != "Text" { failures.append("T2: displayName '\(m.displayName ?? "nil")' != 'Text'") }
            if m.isExpanded != true { failures.append("T2: isExpanded \(String(describing: m.isExpanded)) != true") }
            if m.updatedAt != created { failures.append("T2: updatedAt not backfilled to createdAt") }
            if m.specializedType != nil { failures.append("T2: specializedType should be nil in 3.1a") }
        }

        // T3 — three audio items: "Voice", "Voice 2", "Voice 3".
        do {
            ran += 1
            let items = (0..<3).map { i in
                makeItem(id: "t3-\(i)", type: .audio, file: "a\(i).m4a", transcript: "t\(i)", durationSeconds: Double(i))
            }
            var node = makeNode(items: items)
            _ = migrateEntrySchemaIfNeeded(&node)
            let names = node.items.map { $0.displayName ?? "nil" }
            if names != ["Voice", "Voice 2", "Voice 3"] {
                failures.append("T3: \(names) != [Voice, Voice 2, Voice 3]")
            }
        }

        // T4 — mixed types: counters reset across types. Text + Voice +
        // Image, each first-of-its-kind, all bare defaults.
        do {
            ran += 1
            let items = [
                makeItem(id: "t4-a", type: .text, content: "x"),
                makeItem(id: "t4-b", type: .audio, file: "v.m4a", transcript: "", durationSeconds: 0),
                makeItem(id: "t4-c", type: .image, file: "i.jpg"),
            ]
            var node = makeNode(items: items)
            _ = migrateEntrySchemaIfNeeded(&node)
            let names = node.items.map { $0.displayName ?? "nil" }
            if names != ["Text", "Voice", "Image"] {
                failures.append("T4: \(names) != [Text, Voice, Image]")
            }
        }

        // T5 — full coverage: all six basic types, with duplicates for
        // text and audio. Exercises the per-type sequential counter against
        // every enum case.
        do {
            ran += 1
            let items = [
                makeItem(id: "t5-1", type: .text, content: "a"),
                makeItem(id: "t5-2", type: .text, content: "b"),
                makeItem(id: "t5-3", type: .text, content: "c"),
                makeItem(id: "t5-4", type: .audio, file: "1.m4a", transcript: "", durationSeconds: 0),
                makeItem(id: "t5-5", type: .audio, file: "2.m4a", transcript: "", durationSeconds: 0),
                makeItem(id: "t5-6", type: .image, file: "i.jpg"),
                makeItem(id: "t5-7", type: .video, file: "v.mp4", transcript: "", durationSeconds: 0),
                makeItem(id: "t5-8", type: .link, url: "https://x", title: "T", preview: "P"),
                makeItem(id: "t5-9", type: .document, file: "d.pdf"),
            ]
            var node = makeNode(items: items)
            _ = migrateEntrySchemaIfNeeded(&node)
            let names = node.items.map { $0.displayName ?? "nil" }
            let expected = ["Text", "Text 2", "Text 3", "Voice", "Voice 2", "Image", "Video", "Link", "Document"]
            if names != expected {
                failures.append("T5: \(names) != \(expected)")
            }
        }

        // T6 — idempotency: second call returns false, no field changes.
        do {
            ran += 1
            let items = [makeItem(id: "t6", type: .text, content: "z")]
            var node = makeNode(items: items)
            _ = migrateEntrySchemaIfNeeded(&node)
            let snapshot = node.items[0]
            let second = migrateEntrySchemaIfNeeded(&node)
            if second { failures.append("T6: second call returned true, expected no-op") }
            if node.items[0] != snapshot { failures.append("T6: idempotent migration mutated fields") }
        }

        // T7 — losslessness: every legacy content field preserved byte-equal
        // through migration. Build a maximally-populated item per type and
        // diff the pre/post field values.
        do {
            ran += 1
            let created = Date(timeIntervalSince1970: 1_650_000_000)
            let pre: [NodeItem] = [
                NodeItem(id: "tx", type: .text, createdAt: created, content: "**bold** _it_ `code`"),
                NodeItem(id: "au", type: .audio, createdAt: created, file: "voice.m4a", transcript: "hello world", durationSeconds: 12.5),
                NodeItem(id: "im", type: .image, createdAt: created, file: "photo.jpg", description: "a cat"),
                NodeItem(id: "vi", type: .video, createdAt: created, file: "clip.mp4", transcript: "captions", durationSeconds: 30.0),
                NodeItem(id: "lk", type: .link, createdAt: created, url: "https://example.com/x?y=1", title: "Ex", preview: "preview text"),
                NodeItem(id: "dc", type: .document, createdAt: created, file: "doc.pdf"),
            ]
            var node = makeNode(items: pre)
            _ = migrateEntrySchemaIfNeeded(&node)
            for (i, before) in pre.enumerated() {
                let after = node.items[i]
                if after.id != before.id { failures.append("T7[\(i)]: id changed") }
                if after.type != before.type { failures.append("T7[\(i)]: type changed") }
                if after.createdAt != before.createdAt { failures.append("T7[\(i)]: createdAt changed") }
                if after.content != before.content { failures.append("T7[\(i)]: content changed") }
                if after.file != before.file { failures.append("T7[\(i)]: file changed") }
                if after.description != before.description { failures.append("T7[\(i)]: description changed") }
                if after.transcript != before.transcript { failures.append("T7[\(i)]: transcript changed") }
                if after.durationSeconds != before.durationSeconds { failures.append("T7[\(i)]: durationSeconds changed") }
                if after.url != before.url { failures.append("T7[\(i)]: url changed") }
                if after.title != before.title { failures.append("T7[\(i)]: title changed") }
                if after.preview != before.preview { failures.append("T7[\(i)]: preview changed") }
            }
        }

        // T8 — legacy-shape JSON round-trip. Encode an item dict WITHOUT
        // the four new fields (the exact shape that exists on disk in pre-
        // 3.1a corpora), decode, then migrate. Verifies decodeIfPresent
        // tolerates missing keys and migration produces the expected fields.
        do {
            ran += 1
            let legacyJSON: [String: Any] = [
                "id": "legacy-node",
                "title": "old node",
                "summary": "",
                "tags": [],
                "is_meta": false,
                "threads": [],
                "items": [
                    [
                        "id": "i1",
                        "type": "text",
                        "created_at": "2023-01-15T10:00:00Z",
                        "content": "hello legacy"
                    ],
                    [
                        "id": "i2",
                        "type": "audio",
                        "created_at": "2023-01-15T10:01:00Z",
                        "file": "v.m4a",
                        "transcript": "spoken",
                        "duration_seconds": 5.0
                    ]
                ],
                "created_at": "2023-01-15T09:00:00Z",
                "updated_at": "2023-01-15T10:01:00Z"
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: legacyJSON)
                var node = try JSONDecoder.airPad.decode(Node.self, from: data)
                if node.entrySchemaVersion != 0 { failures.append("T8: decoded version \(node.entrySchemaVersion) != 0") }
                if node.items[0].displayName != nil { failures.append("T8: legacy displayName should be nil pre-migration") }
                let didMigrate = migrateEntrySchemaIfNeeded(&node)
                if !didMigrate { failures.append("T8: expected migration on legacy node") }
                if node.items[0].displayName != "Text" { failures.append("T8: post-migration displayName != 'Text'") }
                if node.items[1].displayName != "Voice" { failures.append("T8: post-migration displayName != 'Voice'") }
                if node.items[0].content != "hello legacy" { failures.append("T8: text content lost") }
                if node.items[1].transcript != "spoken" { failures.append("T8: audio transcript lost") }
                // Round-trip back through the encoder to verify it serializes cleanly.
                let reencoded = try JSONEncoder.airPad.encode(node)
                var rehydrated = try JSONDecoder.airPad.decode(Node.self, from: reencoded)
                if rehydrated.entrySchemaVersion != 1 { failures.append("T8: reencoded version \(rehydrated.entrySchemaVersion) != 1") }
                if rehydrated.items[0].displayName != "Text" { failures.append("T8: reencoded displayName lost") }
                let secondMigrate = migrateEntrySchemaIfNeeded(&rehydrated)
                if secondMigrate { failures.append("T8: round-tripped node should not re-migrate") }
            } catch {
                failures.append("T8: JSON path threw: \(error)")
            }
        }

        // T9 — already-migrated node: version=1 already set, displayName
        // populated. Migration must skip entirely; user-edited name preserved.
        do {
            ran += 1
            var item = makeItem(id: "t9", type: .text, content: "x")
            item.displayName = "My Custom Name"
            item.isExpanded = false
            item.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
            var node = makeNode(items: [item])
            node.entrySchemaVersion = 1
            let didMigrate = migrateEntrySchemaIfNeeded(&node)
            if didMigrate { failures.append("T9: migration ran on already-current node") }
            if node.items[0].displayName != "My Custom Name" { failures.append("T9: displayName overwritten") }
            if node.items[0].isExpanded != false { failures.append("T9: isExpanded overwritten") }
        }

        if failures.isEmpty {
            return "EntryMigration: \(ran)/\(ran) passed"
        } else {
            // Include "FAIL" so SubstrateInspectView's color logic surfaces red.
            return "EntryMigration FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Fixture helpers

    private static func makeNode(items: [NodeItem]) -> Node {
        Node(
            id: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "fixture",
            summary: "",
            tags: [],
            items: items
        )
    }

    private static func makeItem(
        id: String,
        type: NodeItemType,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        content: String? = nil,
        file: String? = nil,
        description: String? = nil,
        transcript: String? = nil,
        durationSeconds: Double? = nil,
        url: String? = nil,
        title: String? = nil,
        preview: String? = nil
    ) -> NodeItem {
        NodeItem(
            id: id,
            type: type,
            createdAt: createdAt,
            content: content,
            file: file,
            description: description,
            transcript: transcript,
            durationSeconds: durationSeconds,
            url: url,
            title: title,
            preview: preview
        )
    }
}
