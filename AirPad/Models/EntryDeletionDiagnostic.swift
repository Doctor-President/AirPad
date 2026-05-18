import Foundation

/// Stage 3.1b — entry-deletion file-cleanup self-test. Permanent diagnostic
/// infrastructure (not throwaway scaffolding): verifies on-device that
/// `iCloudDriveService.deleteItemFile` actually removes media files and
/// stays as regression protection against future drift in the
/// `saveItemFile` / `deleteItemFile` symmetry.
///
/// Mirrors the `EntryMigrationSelfTest` shape — in-process assertions, no
/// XCTest target, returns a one-line-or-multi-line summary that
/// `SubstrateInspectView` surfaces (green on pass, red on FAIL).
///
/// Uses real `iCloudDriveService` storage (resolved via `setup()` →
/// iCloud-or-local-fallback), but scopes every fixture to a unique
/// `EntryDeletionTest-<UUID>` node ID so collisions with user data are
/// impossible. Each test self-cleans the node directory at the end via
/// `deleteNode(id:)`. Leftover fixtures from a crashed mid-run still don't
/// pollute UI — those IDs never appear in `nodes.json` and are invisible
/// to `CorpusStore.loadAllNodes` only because they're file-only fixtures
/// (the per-node directory exists but no `node.json` is registered in the
/// store).
///
/// Coverage:
///   T1 — saveItemFile + deleteItemFile round-trip removes a .m4a
///   T2 — deleteItemFile returns false when the target file is missing
///   T3 — deleteItemFile preserves a sibling file in the same items/ dir
///   T4 — deleteItemFile preserves files belonging to a different node
///   T5 — handles every media extension we ship (m4a, jpg, mp4, pdf)
///   T6 — AT19.3c link OG sidecar: dotted extension `og.jpg` round-trips
///        AND a sibling primary media file under the same itemID survives
///        (the AT19.3c sidecar-cleanup branch fires independently of
///        `item.file` cleanup, so a regression that confuses the two
///        would corrupt user media).
@available(iOS 17.0, *)
@MainActor
enum EntryDeletionDiagnostic {

    static func run() async -> String {
        let service = iCloudDriveService()
        await service.setup()

        var failures: [String] = []
        var ran = 0
        var cleanupNodeIDs: Set<String> = []

        // T1 — round-trip: save a .m4a, confirm it exists, delete it, confirm
        // it's gone and the call returned true.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let itemID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let src = try writeTempFile(name: "\(itemID).m4a", bytes: 32)
                try await service.saveItemFile(nodeID: nodeID, itemID: itemID, sourceURL: src, fileExtension: "m4a")
                if !(await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: "m4a")) {
                    failures.append("T1: file did not appear after saveItemFile")
                }
                let removed = try await service.deleteItemFile(nodeID: nodeID, itemID: itemID, fileExtension: "m4a")
                if !removed { failures.append("T1: deleteItemFile returned false on present file") }
                if await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: "m4a") {
                    failures.append("T1: file still on disk after deleteItemFile")
                }
            } catch {
                failures.append("T1: threw \(error)")
            }
        }

        // T2 — missing file: deleteItemFile on a never-saved item returns
        // false and does not throw (the inconsistency CorpusStore tolerates).
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let itemID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let removed = try await service.deleteItemFile(nodeID: nodeID, itemID: itemID, fileExtension: "m4a")
                if removed { failures.append("T2: returned true for missing file") }
            } catch {
                failures.append("T2: threw on missing file \(error)")
            }
        }

        // T3 — sibling preservation: deleting one item file in a node leaves
        // other item files in the same `items/` dir untouched.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let keepID = UUID().uuidString
            let killID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let keepSrc = try writeTempFile(name: "\(keepID).jpg", bytes: 16)
                let killSrc = try writeTempFile(name: "\(killID).jpg", bytes: 16)
                try await service.saveItemFile(nodeID: nodeID, itemID: keepID, sourceURL: keepSrc, fileExtension: "jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: killID, sourceURL: killSrc, fileExtension: "jpg")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: killID, fileExtension: "jpg")
                if !(await service.itemFileExists(nodeID: nodeID, itemID: keepID, fileExtension: "jpg")) {
                    failures.append("T3: sibling file was removed")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: killID, fileExtension: "jpg") {
                    failures.append("T3: target file still present")
                }
            } catch {
                failures.append("T3: threw \(error)")
            }
        }

        // T4 — cross-node isolation: deleting an item in node A does not
        // touch an identically-named item under node B's directory.
        do {
            ran += 1
            let nodeA = "EntryDeletionTest-\(UUID().uuidString)"
            let nodeB = "EntryDeletionTest-\(UUID().uuidString)"
            let sharedItemID = UUID().uuidString
            cleanupNodeIDs.insert(nodeA)
            cleanupNodeIDs.insert(nodeB)
            do {
                let srcA = try writeTempFile(name: "A-\(sharedItemID).mp4", bytes: 24)
                let srcB = try writeTempFile(name: "B-\(sharedItemID).mp4", bytes: 24)
                try await service.saveItemFile(nodeID: nodeA, itemID: sharedItemID, sourceURL: srcA, fileExtension: "mp4")
                try await service.saveItemFile(nodeID: nodeB, itemID: sharedItemID, sourceURL: srcB, fileExtension: "mp4")
                _ = try await service.deleteItemFile(nodeID: nodeA, itemID: sharedItemID, fileExtension: "mp4")
                if await service.itemFileExists(nodeID: nodeA, itemID: sharedItemID, fileExtension: "mp4") {
                    failures.append("T4: node A file still present")
                }
                if !(await service.itemFileExists(nodeID: nodeB, itemID: sharedItemID, fileExtension: "mp4")) {
                    failures.append("T4: node B file collaterally removed")
                }
            } catch {
                failures.append("T4: threw \(error)")
            }
        }

        // T5 — every extension we ship: voice (.m4a), image (.jpg), video
        // (.mp4), document (.pdf). The save/delete primitive is
        // extension-agnostic; this test pins that contract so a future
        // ext-specific code path in saveItemFile/deleteItemFile breaks here
        // rather than at delete time on the user's device.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            cleanupNodeIDs.insert(nodeID)
            let exts = ["m4a", "jpg", "mp4", "pdf"]
            do {
                for ext in exts {
                    let itemID = UUID().uuidString
                    let src = try writeTempFile(name: "\(itemID).\(ext)", bytes: 8)
                    try await service.saveItemFile(nodeID: nodeID, itemID: itemID, sourceURL: src, fileExtension: ext)
                    if !(await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: ext)) {
                        failures.append("T5[\(ext)]: file not present after save")
                        continue
                    }
                    let removed = try await service.deleteItemFile(nodeID: nodeID, itemID: itemID, fileExtension: ext)
                    if !removed { failures.append("T5[\(ext)]: delete returned false") }
                    if await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: ext) {
                        failures.append("T5[\(ext)]: file still present after delete")
                    }
                }
            } catch {
                failures.append("T5: threw \(error)")
            }
        }

        // T6 — AT19.3c OG sidecar with dotted extension. Two assertions:
        //   (a) `og.jpg` round-trips through save + delete primitives,
        //       proving the extension-agnostic contract handles dotted
        //       extensions identically to bare ones (jpg, mp4, …).
        //   (b) When an item carries BOTH a primary media file (`<id>.jpg`)
        //       and an OG sidecar (`<id>.og.jpg`), deleting the sidecar
        //       leaves the primary intact. A regression where the dotted
        //       extension was misparsed could silently delete the primary
        //       file at delete-entry time on a user's device; this pins
        //       that contract so it breaks here first.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let itemID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let primarySrc = try writeTempFile(name: "\(itemID).primary.jpg", bytes: 24)
                let sidecarSrc = try writeTempFile(name: "\(itemID).sidecar.jpg", bytes: 24)
                try await service.saveItemFile(nodeID: nodeID, itemID: itemID, sourceURL: primarySrc, fileExtension: "jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: itemID, sourceURL: sidecarSrc, fileExtension: "og.jpg")
                if !(await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: "og.jpg")) {
                    failures.append("T6: og.jpg did not appear after saveItemFile")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: "jpg")) {
                    failures.append("T6: primary .jpg did not appear after saveItemFile")
                }
                let removed = try await service.deleteItemFile(nodeID: nodeID, itemID: itemID, fileExtension: "og.jpg")
                if !removed { failures.append("T6: deleteItemFile returned false on present og.jpg") }
                if await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: "og.jpg") {
                    failures.append("T6: og.jpg still on disk after deleteItemFile")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: itemID, fileExtension: "jpg")) {
                    failures.append("T6: primary .jpg collaterally removed when deleting og.jpg sibling")
                }
            } catch {
                failures.append("T6: threw \(error)")
            }
        }

        // Cleanup: drop every fixture node directory we created. Failures
        // here are silent — leftover EntryDeletionTest-<UUID> dirs are
        // invisible to the store (no node.json registered) and don't affect
        // user data.
        for nodeID in cleanupNodeIDs {
            try? await service.deleteNode(id: nodeID)
        }

        if failures.isEmpty {
            return "EntryDeletion: \(ran)/\(ran) passed"
        } else {
            return "EntryDeletion FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Helpers

    /// Writes `bytes` zero-filled bytes to a unique path under
    /// `FileManager.temporaryDirectory` and returns the URL. The caller
    /// hands this URL to `saveItemFile`, which copies (not moves), so the
    /// tempfile is left behind — OS cleans temp on its own schedule and
    /// the bytes are uniqued so collisions don't matter.
    private static func writeTempFile(name: String, bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = Data(count: bytes)
        try data.write(to: url, options: .atomic)
        return url
    }
}
