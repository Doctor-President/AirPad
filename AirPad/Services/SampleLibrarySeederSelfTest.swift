import Foundation

/// Brief N §2 — isolated end-to-end check of `SampleLibrarySeeder`, launch-arg
/// gated (`-SampleSeedSelfTest`), DEBUG only. Runs entirely against a THROWAWAY
/// temp directory + the bundled `SampleLibrary/`, so it never touches the real
/// iCloud/local container. Verifies: the bundle seeds, the marker is written,
/// baked card.json rides along where present, and — the load-bearing property —
/// removal deletes every seeded node while a user's OWN node (and a tag it shares
/// with the sample) survives.
enum SampleLibrarySeederSelfTest {
    static func run() -> String {
        var failures: [String] = []
        var checks = 0
        func check(_ cond: Bool, _ label: String) {
            checks += 1
            if !cond { failures.append(label) }
        }

        let fm = FileManager.default
        let enc = JSONEncoder.airPad
        let dec = JSONDecoder.airPad
        let root = fm.temporaryDirectory.appendingPathComponent("SampleSeedSelfTest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: root.appendingPathComponent("nodes"), withIntermediateDirectories: true)

            guard let bundle = SampleLibrarySeeder.bundledLibraryURL() else {
                return "FAIL: SampleLibrary not bundled (Bundle.main.url returned nil)"
            }

            // --- gate: fresh + empty ---
            check(SampleLibrarySeeder.shouldSeed(containerRoot: root), "shouldSeed true on empty root")

            // --- seed ---
            let manifest = try SampleLibrarySeeder.seed(containerRoot: root, bundleRoot: bundle)
            check(manifest.nodeIDs.count == 5, "seeded 5 nodes (got \(manifest.nodeIDs.count))")
            check(manifest.collectionIDs.contains("sample-library"), "seeded sample-library collection")
            check(SampleLibrarySeeder.markerExists(containerRoot: root), "marker written")
            check(!SampleLibrarySeeder.shouldSeed(containerRoot: root), "shouldSeed false after seed")

            // --- node dirs + baked card.json copy / skip ---
            func nodeExists(_ id: String) -> Bool {
                fm.fileExists(atPath: root.appendingPathComponent("nodes/\(id)/node.json").path)
            }
            func cardExists(_ id: String) -> Bool {
                fm.fileExists(atPath: root.appendingPathComponent("nodes/\(id)/card.json").path)
            }
            let n1 = "5A3D1E00-0000-4000-8000-000000000001"
            let n3 = "5A3D1E00-0000-4000-8000-000000000003"
            check(nodeExists(n1) && nodeExists(n3), "node.json copied")
            check(cardExists(n1), "baked card.json copied where present")
            check(!cardExists(n3), "card.json absent where not authored")

            // --- side files merged ---
            let cols = try dec.decode([NodeCollection].self,
                                      from: Data(contentsOf: root.appendingPathComponent("collections.json")))
            check(cols.contains { $0.id == "sample-library" }, "collections.json has sample-library")
            let tags = try dec.decode([Tag].self,
                                      from: Data(contentsOf: root.appendingPathComponent("tags.json")))
            check(Set(["coffee", "recipe", "idea"]).isSubset(of: Set(tags.map { $0.name })), "tags merged")
            let defs = try dec.decode(FieldDefinitionStore.self,
                                      from: Data(contentsOf: root.appendingPathComponent("field_definitions.json")))
            check(defs.definitions.count >= 2, "field definitions merged")

            // --- inject a USER node that SHARES a seeded tag ("coffee") ---
            let userID = "0BE0FACE-0000-4000-8000-000000000009"
            let userNode = Node(id: userID, createdAt: Date(), updatedAt: Date(),
                                title: "My own note", summary: "", tags: ["coffee"],
                                entrySchemaVersion: 4)
            let userDir = root.appendingPathComponent("nodes/\(userID)")
            try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
            try enc.encode(userNode).write(to: userDir.appendingPathComponent("node.json"), options: .atomic)

            // --- remove ---
            let removed = try SampleLibrarySeeder.remove(containerRoot: root)
            check(removed?.nodeIDs.count == 5, "removal reports 5 seeded nodes")

            // user node SURVIVES; all seeded nodes GONE; marker GONE.
            check(nodeExists(userID), "USER node survives removal")
            let seededGone = manifest.nodeIDs.allSatisfy { !nodeExists($0) }
            check(seededGone, "all seeded nodes deleted")
            check(!SampleLibrarySeeder.markerExists(containerRoot: root), "marker deleted")

            // sample-library collection gone.
            let colsAfter = try dec.decode([NodeCollection].self,
                                           from: Data(contentsOf: root.appendingPathComponent("collections.json")))
            check(!colsAfter.contains { $0.id == "sample-library" }, "sample-library collection removed")

            // tag guard: "coffee" KEPT (user node uses it); "recipe"/"idea" REMOVED.
            let tagsAfter = try dec.decode([Tag].self,
                                           from: Data(contentsOf: root.appendingPathComponent("tags.json")))
            let namesAfter = Set(tagsAfter.map { $0.name })
            check(namesAfter.contains("coffee"), "shared tag 'coffee' kept (user node references it)")
            check(!namesAfter.contains("recipe") && !namesAfter.contains("idea"), "unreferenced seeded tags removed")

            // field defs removed (no surviving node references them).
            let defsAfter = try dec.decode(FieldDefinitionStore.self,
                                           from: Data(contentsOf: root.appendingPathComponent("field_definitions.json")))
            check(defsAfter.definitions.isEmpty, "unreferenced seeded field definitions removed")
        } catch {
            return "FAIL: threw \(error)"
        }

        return failures.isEmpty
            ? "PASS: \(checks)/\(checks) checks"
            : "FAIL (\(failures.count)/\(checks)): " + failures.joined(separator: "; ")
    }
}
