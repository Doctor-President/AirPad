import Foundation

/// Brief N §2 / Brief R Step 4 — isolated end-to-end check of `SampleLibrarySeeder`,
/// launch-arg gated (`-SampleSeedSelfTest`), DEBUG only. Runs entirely against a
/// THROWAWAY temp directory + the bundled `SampleLibrary/`, so it never touches the
/// real container. BUNDLE-AGNOSTIC: it reads the bundle's actual node/sidecar counts
/// rather than hardcoding them, so it tracks the sample as it grows (5 → 210 …).
/// Verifies: the bundle seeds; the marker is written; baked `card.json` AND
/// `blocks.json` ride along; and — the load-bearing property — removal deletes every
/// seeded node dir (with its sidecars) while a user's OWN node (and a tag it shares)
/// survives.
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

            // --- bundle facts (agnostic to count) ---
            let bundleNodesDir = bundle.appendingPathComponent("nodes")
            let bundleDirs = (try? fm.contentsOfDirectory(at: bundleNodesDir,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            func hasFile(_ dir: URL, _ name: String) -> Bool {
                fm.fileExists(atPath: dir.appendingPathComponent(name).path)
            }
            let bundleNodeIDs = bundleDirs.filter { hasFile($0, "node.json") }.map { $0.lastPathComponent }
            let bundleCards = bundleDirs.filter { hasFile($0, "card.json") }.count
            let bundleBlocks = bundleDirs.filter { hasFile($0, "blocks.json") }.count
            check(!bundleNodeIDs.isEmpty, "bundle has node dirs (got \(bundleNodeIDs.count))")

            // --- gate: fresh + empty ---
            check(SampleLibrarySeeder.shouldSeed(containerRoot: root), "shouldSeed true on empty root")

            // --- seed ---
            let manifest = try SampleLibrarySeeder.seed(containerRoot: root, bundleRoot: bundle)
            check(manifest.nodeIDs.count == bundleNodeIDs.count,
                  "seeded all bundle nodes (\(manifest.nodeIDs.count) vs bundle \(bundleNodeIDs.count))")
            check(SampleLibrarySeeder.markerExists(containerRoot: root), "marker written")
            check(!SampleLibrarySeeder.shouldSeed(containerRoot: root), "shouldSeed false after seed")

            // --- node dirs + baked sidecars (card.json + blocks.json) copied ---
            func inRoot(_ id: String, _ file: String) -> Bool {
                fm.fileExists(atPath: root.appendingPathComponent("nodes/\(id)/\(file)").path)
            }
            check(bundleNodeIDs.allSatisfy { inRoot($0, "node.json") }, "all node.json copied")
            let copiedCards = bundleNodeIDs.filter { inRoot($0, "card.json") }.count
            let copiedBlocks = bundleNodeIDs.filter { inRoot($0, "blocks.json") }.count
            check(copiedCards == bundleCards, "baked card.json copied (\(copiedCards)/\(bundleCards))")
            check(copiedBlocks == bundleBlocks, "baked blocks.json copied (\(copiedBlocks)/\(bundleBlocks))")

            // --- side files merged (non-empty) ---
            let cols = try dec.decode([NodeCollection].self,
                                      from: Data(contentsOf: root.appendingPathComponent("collections.json")))
            check(!cols.isEmpty, "collections merged (\(cols.count))")
            let tags = try dec.decode([Tag].self,
                                      from: Data(contentsOf: root.appendingPathComponent("tags.json")))
            check(tags.contains { $0.name == "coffee" }, "tags merged (coffee present)")
            let defs = try dec.decode(FieldDefinitionStore.self,
                                      from: Data(contentsOf: root.appendingPathComponent("field_definitions.json")))
            check(!defs.definitions.isEmpty, "field definitions merged (\(defs.definitions.count))")

            // --- Brief AF5 — pinned chats were DROPPED (T's ruling): the bundle ships
            //     no chats.json, so a fresh seed reports chatIDs == 0. The seeder's chat
            //     CAPABILITY stays exercised below (a user chat is injected and must
            //     survive removal). When bundle chats ever return, the citation-resolution
            //     invariant (a chip opens a real node) is re-checked under the guard. ---
            let bundleChatCount: Int = {
                guard let d = try? Data(contentsOf: bundle.appendingPathComponent("chats.json")),
                      let cs = try? dec.decode([Chat].self, from: d) else { return 0 }
                return cs.count
            }()
            check(bundleChatCount == 0, "no bundled pinned chats (Brief AF5 removed them)")
            check(manifest.chatIDs.count == bundleChatCount,
                  "seeded chat count matches bundle (\(manifest.chatIDs.count)/\(bundleChatCount))")
            let seededChats = (try? dec.decode([Chat].self,
                from: Data(contentsOf: root.appendingPathComponent("chats.json")))) ?? []
            check(Set(manifest.chatIDs).isSubset(of: Set(seededChats.map { $0.id.uuidString })),
                  "seeded chats present in chats.json")
            if bundleChatCount > 0 {
                let seededNodeSet = Set(manifest.nodeIDs)
                let citedNodes = seededChats
                    .flatMap { $0.messages.flatMap { $0.citations ?? [] } }
                    .compactMap { $0.nodeID }
                check(!citedNodes.isEmpty, "pinned chats carry citations (\(citedNodes.count))")
                check(citedNodes.allSatisfy { seededNodeSet.contains($0) },
                      "every pinned-chat citation resolves to a seeded node")
            }

            // Inject a USER chat that must SURVIVE removal (parallels the user node).
            let userChatID = UUID()
            var chatsWithUser = seededChats
            chatsWithUser.append(Chat(id: userChatID, title: "My chat",
                                      createdAt: Date(), updatedAt: Date(), messages: []))
            try enc.encode(chatsWithUser)
                .write(to: root.appendingPathComponent("chats.json"), options: .atomic)

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
            check(removed?.nodeIDs.count == bundleNodeIDs.count, "removal reports all seeded nodes")

            // user node SURVIVES; all seeded node dirs (+ their sidecars) GONE; marker GONE.
            check(inRoot(userID, "node.json"), "USER node survives removal")
            check(manifest.nodeIDs.allSatisfy { !inRoot($0, "node.json") }, "all seeded node dirs deleted")
            check(!manifest.nodeIDs.contains { inRoot($0, "blocks.json") }, "seeded blocks.json removed with their dirs")
            check(!manifest.nodeIDs.contains { inRoot($0, "card.json") }, "seeded card.json removed with their dirs")
            check(!SampleLibrarySeeder.markerExists(containerRoot: root), "marker deleted")

            // Brief AC5 — Remove deletes the seeded (pinned) chats; the USER chat survives.
            let chatsAfter = (try? dec.decode([Chat].self,
                from: Data(contentsOf: root.appendingPathComponent("chats.json")))) ?? []
            let idsAfter = Set(chatsAfter.map { $0.id.uuidString })
            check(!manifest.chatIDs.contains { idsAfter.contains($0) }, "seeded pinned chats removed on Remove")
            check(idsAfter.contains(userChatID.uuidString), "USER chat survives removal")

            // tag guard: "coffee" KEPT (user node uses it); an unreferenced seeded tag REMOVED.
            let namesAfter = Set((try dec.decode([Tag].self,
                from: Data(contentsOf: root.appendingPathComponent("tags.json")))).map { $0.name })
            check(namesAfter.contains("coffee"), "shared tag 'coffee' kept (user node references it)")
            check(!namesAfter.contains("horror"), "unreferenced seeded tag 'horror' removed")

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
