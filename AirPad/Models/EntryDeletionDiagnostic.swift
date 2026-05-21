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
///   T7 — Stage 4.2 gallery delete round-trip: a 2-item gallery (two
///        distinct GalleryItem IDs in the same items/ dir) survives a
///        single-item delete with the target file gone and the sibling
///        file intact. Distinct from T3 in framing — T3 is "two unrelated
///        items in the same node"; T7 is "two items inside one
///        `.imageVideo` entry's mediaItems array" (same file shape, but
///        the diagnostic anchor for the gallery deletion path).
///   T8 — Stage 4.2 multi-item gallery middle-delete: a 3-item gallery
///        with one delete at the **middle** index leaves both edge items
///        (first + last) intact. Fan-out beyond T3/T7's 2-item case, and
///        pins the ordering-preservation contract — a regression where
///        the file primitive walks the wrong itemID would surface here
///        with one of the edge items missing.
///   T9 — Stage 4.5 multi-link entry delete: a 2-item link gallery where
///        each LinkItem has BOTH an OG image sidecar (`og.jpg`) AND a
///        favicon sidecar (`favicon.ico`) — four sidecars across two
///        items in one entry. Deleting all four (the shape
///        `CorpusStore.deleteEntry` produces for a multi-link entry via
///        `deleteLinkItemSidecars`) removes each cleanly without touching
///        an unrelated sibling sidecar in the same node. Parallel to T7's
///        2-item shape but pins the dual-sidecar-per-item contract specific
///        to LinkItem.
///   T10 — Stage 4.5 per-link delete from a multi-link entry: a 3-item
///        link gallery, each LinkItem with `og.jpg` + `favicon.ico`.
///        Deleting just the middle LinkItem's two sidecars leaves both
///        edge items' four sidecars intact. Parallel to T8 (middle-delete
///        ordering preservation) but for LinkItem's dual sidecars.
///   T11 — Stage 4.6 single-doc entry delete: one DocumentItem carrying
///        a file blob (`.pdf`) AND a thumbnail sidecar (`.thumb.jpg`) at
///        the same itemID, with an unrelated bystander file elsewhere in
///        the same node. Deleting both DocumentItem files (the shape
///        `deleteDocumentItemSidecars` produces) removes them cleanly
///        and the bystander survives. Anchors the single-doc entry-
///        delete contract — analogous to T1 for documents, but with the
///        dotted-extension sidecar arm exercised.
///   T12 — Stage 4.6 multi-doc entry delete: 2 DocumentItems each with
///        file blob + thumbnail (4 files total) + bystander. Deleting
///        all four (the shape `deleteEntry`'s `documentItems` iteration
///        produces for a multi-doc entry) removes each cleanly and the
///        bystander survives. Parallel to T9's multi-link entry shape
///        but pins the DocumentItem blob-plus-thumbnail contract.
///   T13 — Stage 4.6 per-doc middle delete from 3-doc gallery: 3
///        DocumentItems each with file blob + thumbnail. Deleting only
///        the middle item's two files leaves both edge items' four
///        files intact. Parallel to T10 (middle-delete ordering
///        preservation) but for DocumentItem's blob-plus-thumbnail.
///   T14 — Stage 4.6 DocumentItem without thumbnail (TXT/MD/RTF shape):
///        DocumentItem with only the file blob (`.txt`) and no
///        `.thumb.<ext>` sidecar. Deleting the blob succeeds; the
///        `thumbnailFile == nil` branch in `deleteDocumentItemSidecars`
///        skips the sidecar arm entirely. A regression that treated
///        nil-thumbnail as `thumb.""` (or that always called the
///        sidecar delete unconditionally) would surface here either as
///        a thrown error or as a phantom delete attempt.
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

        // T7 — Stage 4.2 gallery delete round-trip: 2-item gallery shape.
        // Two GalleryItems persisted as siblings in one node's items/ dir;
        // delete one; verify the target is gone AND the sibling survives.
        // The shape matches what `CorpusStore.deleteGalleryItem` produces
        // at the file-primitive layer for a 2→1 gallery shrink.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let item1ID = UUID().uuidString
            let item2ID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let src1 = try writeTempFile(name: "\(item1ID).jpg", bytes: 12)
                let src2 = try writeTempFile(name: "\(item2ID).mp4", bytes: 12)
                try await service.saveItemFile(nodeID: nodeID, itemID: item1ID, sourceURL: src1, fileExtension: "jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: item2ID, sourceURL: src2, fileExtension: "mp4")
                let removed = try await service.deleteItemFile(nodeID: nodeID, itemID: item1ID, fileExtension: "jpg")
                if !removed { failures.append("T7: deleteItemFile returned false on present gallery item") }
                if await service.itemFileExists(nodeID: nodeID, itemID: item1ID, fileExtension: "jpg") {
                    failures.append("T7: gallery item 1 still on disk after delete")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: item2ID, fileExtension: "mp4")) {
                    failures.append("T7: gallery item 2 collaterally removed")
                }
            } catch {
                failures.append("T7: threw \(error)")
            }
        }

        // T8 — Stage 4.2 multi-item gallery middle-delete: 3 GalleryItems
        // in one node's items/ dir; delete the middle one. Both edges
        // (item 0 and item 2) must survive. Pins the ordering-preservation
        // contract for the file primitive when called from the gallery
        // delete path with a non-edge index.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let item0ID = UUID().uuidString
            let item1ID = UUID().uuidString
            let item2ID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let src0 = try writeTempFile(name: "\(item0ID).jpg", bytes: 12)
                let src1 = try writeTempFile(name: "\(item1ID).jpg", bytes: 12)
                let src2 = try writeTempFile(name: "\(item2ID).jpg", bytes: 12)
                try await service.saveItemFile(nodeID: nodeID, itemID: item0ID, sourceURL: src0, fileExtension: "jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: item1ID, sourceURL: src1, fileExtension: "jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: item2ID, sourceURL: src2, fileExtension: "jpg")
                let removed = try await service.deleteItemFile(nodeID: nodeID, itemID: item1ID, fileExtension: "jpg")
                if !removed { failures.append("T8: deleteItemFile returned false on present middle item") }
                if await service.itemFileExists(nodeID: nodeID, itemID: item1ID, fileExtension: "jpg") {
                    failures.append("T8: middle item still on disk after delete")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: item0ID, fileExtension: "jpg")) {
                    failures.append("T8: leading edge item collaterally removed")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: item2ID, fileExtension: "jpg")) {
                    failures.append("T8: trailing edge item collaterally removed")
                }
            } catch {
                failures.append("T8: threw \(error)")
            }
        }

        // T9 — Stage 4.5 multi-link entry delete: 2 LinkItems in one
        // node's items/ dir, each with an OG image sidecar (`og.jpg`)
        // AND a favicon sidecar (`favicon.ico`). Four sidecars total
        // across two LinkItem IDs. Delete all four (the shape
        // `deleteLinkItemSidecars` produces when called from
        // `deleteEntry` for a multi-link entry); verify each is gone
        // AND an unrelated bystander sidecar in the same node survives.
        // Anchors the LinkItem-specific dual-sidecar contract.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let link1ID = UUID().uuidString
            let link2ID = UUID().uuidString
            let bystanderID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let l1og = try writeTempFile(name: "\(link1ID).og.jpg", bytes: 12)
                let l1fav = try writeTempFile(name: "\(link1ID).favicon.ico", bytes: 12)
                let l2og = try writeTempFile(name: "\(link2ID).og.jpg", bytes: 12)
                let l2fav = try writeTempFile(name: "\(link2ID).favicon.ico", bytes: 12)
                let bys = try writeTempFile(name: "\(bystanderID).jpg", bytes: 12)
                try await service.saveItemFile(nodeID: nodeID, itemID: link1ID, sourceURL: l1og, fileExtension: "og.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: link1ID, sourceURL: l1fav, fileExtension: "favicon.ico")
                try await service.saveItemFile(nodeID: nodeID, itemID: link2ID, sourceURL: l2og, fileExtension: "og.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: link2ID, sourceURL: l2fav, fileExtension: "favicon.ico")
                try await service.saveItemFile(nodeID: nodeID, itemID: bystanderID, sourceURL: bys, fileExtension: "jpg")

                // Delete all four LinkItem sidecars (the entry-delete shape).
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: link1ID, fileExtension: "og.jpg")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: link1ID, fileExtension: "favicon.ico")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: link2ID, fileExtension: "og.jpg")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: link2ID, fileExtension: "favicon.ico")

                if await service.itemFileExists(nodeID: nodeID, itemID: link1ID, fileExtension: "og.jpg") {
                    failures.append("T9: link1 og.jpg still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: link1ID, fileExtension: "favicon.ico") {
                    failures.append("T9: link1 favicon.ico still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: link2ID, fileExtension: "og.jpg") {
                    failures.append("T9: link2 og.jpg still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: link2ID, fileExtension: "favicon.ico") {
                    failures.append("T9: link2 favicon.ico still on disk after delete")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: bystanderID, fileExtension: "jpg")) {
                    failures.append("T9: bystander sidecar collaterally removed")
                }
            } catch {
                failures.append("T9: threw \(error)")
            }
        }

        // T10 — Stage 4.5 per-link delete from a multi-link entry:
        // 3 LinkItems in one entry's linkItems array, each with
        // `og.jpg` + `favicon.ico`. Delete only the middle item's two
        // sidecars (the shape `removeLinkItem` produces for a per-tile
        // delete). Both edge items' four sidecars must survive. Pins
        // the ordering-preservation contract for the LinkItem path
        // when the delete is non-edge, parallel to T8.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let link0ID = UUID().uuidString
            let link1ID = UUID().uuidString
            let link2ID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let l0og = try writeTempFile(name: "\(link0ID).og.jpg", bytes: 12)
                let l0fav = try writeTempFile(name: "\(link0ID).favicon.ico", bytes: 12)
                let l1og = try writeTempFile(name: "\(link1ID).og.jpg", bytes: 12)
                let l1fav = try writeTempFile(name: "\(link1ID).favicon.ico", bytes: 12)
                let l2og = try writeTempFile(name: "\(link2ID).og.jpg", bytes: 12)
                let l2fav = try writeTempFile(name: "\(link2ID).favicon.ico", bytes: 12)
                try await service.saveItemFile(nodeID: nodeID, itemID: link0ID, sourceURL: l0og, fileExtension: "og.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: link0ID, sourceURL: l0fav, fileExtension: "favicon.ico")
                try await service.saveItemFile(nodeID: nodeID, itemID: link1ID, sourceURL: l1og, fileExtension: "og.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: link1ID, sourceURL: l1fav, fileExtension: "favicon.ico")
                try await service.saveItemFile(nodeID: nodeID, itemID: link2ID, sourceURL: l2og, fileExtension: "og.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: link2ID, sourceURL: l2fav, fileExtension: "favicon.ico")

                // Per-link delete of the middle LinkItem.
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: link1ID, fileExtension: "og.jpg")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: link1ID, fileExtension: "favicon.ico")

                if await service.itemFileExists(nodeID: nodeID, itemID: link1ID, fileExtension: "og.jpg") {
                    failures.append("T10: middle link og.jpg still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: link1ID, fileExtension: "favicon.ico") {
                    failures.append("T10: middle link favicon.ico still on disk after delete")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: link0ID, fileExtension: "og.jpg")) {
                    failures.append("T10: leading link og.jpg collaterally removed")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: link0ID, fileExtension: "favicon.ico")) {
                    failures.append("T10: leading link favicon.ico collaterally removed")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: link2ID, fileExtension: "og.jpg")) {
                    failures.append("T10: trailing link og.jpg collaterally removed")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: link2ID, fileExtension: "favicon.ico")) {
                    failures.append("T10: trailing link favicon.ico collaterally removed")
                }
            } catch {
                failures.append("T10: threw \(error)")
            }
        }

        // T11 — Stage 4.6 single-doc entry delete: one DocumentItem with
        // a file blob (`.pdf`) + a thumbnail sidecar (`.thumb.jpg`) at
        // the same itemID, plus an unrelated bystander file in the
        // same node. Deleting both DocumentItem files (the shape
        // `deleteDocumentItemSidecars` produces) removes them cleanly;
        // the bystander survives. Anchors the single-doc entry-delete
        // contract — analogous to T1 for documents but with the
        // dotted-extension sidecar arm exercised in parallel.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let docID = UUID().uuidString
            let bystanderID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let blobSrc = try writeTempFile(name: "\(docID).pdf", bytes: 24)
                let thumbSrc = try writeTempFile(name: "\(docID).thumb.jpg", bytes: 12)
                let bys = try writeTempFile(name: "\(bystanderID).jpg", bytes: 12)
                try await service.saveItemFile(nodeID: nodeID, itemID: docID, sourceURL: blobSrc, fileExtension: "pdf")
                try await service.saveItemFile(nodeID: nodeID, itemID: docID, sourceURL: thumbSrc, fileExtension: "thumb.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: bystanderID, sourceURL: bys, fileExtension: "jpg")

                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: docID, fileExtension: "pdf")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: docID, fileExtension: "thumb.jpg")

                if await service.itemFileExists(nodeID: nodeID, itemID: docID, fileExtension: "pdf") {
                    failures.append("T11: doc blob still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: docID, fileExtension: "thumb.jpg") {
                    failures.append("T11: doc thumb still on disk after delete")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: bystanderID, fileExtension: "jpg")) {
                    failures.append("T11: bystander collaterally removed")
                }
            } catch {
                failures.append("T11: threw \(error)")
            }
        }

        // T12 — Stage 4.6 multi-doc entry delete: 2 DocumentItems in one
        // node's items/ dir, each with file blob + thumbnail sidecar
        // (4 files total) + an unrelated bystander. Deleting all four
        // (the shape `deleteEntry`'s `documentItems` iteration produces
        // for a multi-doc entry) removes each cleanly; bystander
        // survives. Parallel to T9 but for DocumentItem's blob-plus-
        // thumbnail contract.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let doc1ID = UUID().uuidString
            let doc2ID = UUID().uuidString
            let bystanderID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let d1blob = try writeTempFile(name: "\(doc1ID).pdf", bytes: 12)
                let d1thumb = try writeTempFile(name: "\(doc1ID).thumb.jpg", bytes: 12)
                let d2blob = try writeTempFile(name: "\(doc2ID).docx", bytes: 12)
                let d2thumb = try writeTempFile(name: "\(doc2ID).thumb.jpg", bytes: 12)
                let bys = try writeTempFile(name: "\(bystanderID).jpg", bytes: 12)
                try await service.saveItemFile(nodeID: nodeID, itemID: doc1ID, sourceURL: d1blob, fileExtension: "pdf")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc1ID, sourceURL: d1thumb, fileExtension: "thumb.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc2ID, sourceURL: d2blob, fileExtension: "docx")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc2ID, sourceURL: d2thumb, fileExtension: "thumb.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: bystanderID, sourceURL: bys, fileExtension: "jpg")

                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: doc1ID, fileExtension: "pdf")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: doc1ID, fileExtension: "thumb.jpg")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: doc2ID, fileExtension: "docx")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: doc2ID, fileExtension: "thumb.jpg")

                if await service.itemFileExists(nodeID: nodeID, itemID: doc1ID, fileExtension: "pdf") {
                    failures.append("T12: doc1 blob still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: doc1ID, fileExtension: "thumb.jpg") {
                    failures.append("T12: doc1 thumb still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: doc2ID, fileExtension: "docx") {
                    failures.append("T12: doc2 blob still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: doc2ID, fileExtension: "thumb.jpg") {
                    failures.append("T12: doc2 thumb still on disk after delete")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: bystanderID, fileExtension: "jpg")) {
                    failures.append("T12: bystander collaterally removed")
                }
            } catch {
                failures.append("T12: threw \(error)")
            }
        }

        // T13 — Stage 4.6 per-doc middle delete from 3-doc gallery: 3
        // DocumentItems each with file blob + thumbnail. Delete only
        // the middle item's two files (the shape `removeDocumentItem`
        // produces for a per-tile delete); both edge items' four
        // files must survive. Parallel to T10 but for DocumentItem's
        // blob-plus-thumbnail.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let doc0ID = UUID().uuidString
            let doc1ID = UUID().uuidString
            let doc2ID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let d0blob = try writeTempFile(name: "\(doc0ID).pdf", bytes: 12)
                let d0thumb = try writeTempFile(name: "\(doc0ID).thumb.jpg", bytes: 12)
                let d1blob = try writeTempFile(name: "\(doc1ID).pdf", bytes: 12)
                let d1thumb = try writeTempFile(name: "\(doc1ID).thumb.jpg", bytes: 12)
                let d2blob = try writeTempFile(name: "\(doc2ID).pdf", bytes: 12)
                let d2thumb = try writeTempFile(name: "\(doc2ID).thumb.jpg", bytes: 12)
                try await service.saveItemFile(nodeID: nodeID, itemID: doc0ID, sourceURL: d0blob, fileExtension: "pdf")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc0ID, sourceURL: d0thumb, fileExtension: "thumb.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc1ID, sourceURL: d1blob, fileExtension: "pdf")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc1ID, sourceURL: d1thumb, fileExtension: "thumb.jpg")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc2ID, sourceURL: d2blob, fileExtension: "pdf")
                try await service.saveItemFile(nodeID: nodeID, itemID: doc2ID, sourceURL: d2thumb, fileExtension: "thumb.jpg")

                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: doc1ID, fileExtension: "pdf")
                _ = try await service.deleteItemFile(nodeID: nodeID, itemID: doc1ID, fileExtension: "thumb.jpg")

                if await service.itemFileExists(nodeID: nodeID, itemID: doc1ID, fileExtension: "pdf") {
                    failures.append("T13: middle doc blob still on disk after delete")
                }
                if await service.itemFileExists(nodeID: nodeID, itemID: doc1ID, fileExtension: "thumb.jpg") {
                    failures.append("T13: middle doc thumb still on disk after delete")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: doc0ID, fileExtension: "pdf")) {
                    failures.append("T13: leading doc blob collaterally removed")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: doc0ID, fileExtension: "thumb.jpg")) {
                    failures.append("T13: leading doc thumb collaterally removed")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: doc2ID, fileExtension: "pdf")) {
                    failures.append("T13: trailing doc blob collaterally removed")
                }
                if !(await service.itemFileExists(nodeID: nodeID, itemID: doc2ID, fileExtension: "thumb.jpg")) {
                    failures.append("T13: trailing doc thumb collaterally removed")
                }
            } catch {
                failures.append("T13: threw \(error)")
            }
        }

        // T14 — Stage 4.6 DocumentItem without thumbnail (TXT/MD/RTF
        // shape): DocumentItem with only the file blob (`.txt`) and
        // no `.thumb.<ext>` sidecar. Deleting the blob succeeds; the
        // `thumbnailFile == nil` branch in `deleteDocumentItemSidecars`
        // skips the sidecar arm entirely. Pin the contract by saving
        // *only* the blob, deleting it, then asserting the deletion
        // primitive returns false (not an error) for the never-saved
        // `.thumb.txt` — the idempotent missing-file shape T2 already
        // pinned, but exercised in the no-thumbnail document context.
        do {
            ran += 1
            let nodeID = "EntryDeletionTest-\(UUID().uuidString)"
            let docID = UUID().uuidString
            cleanupNodeIDs.insert(nodeID)
            do {
                let blobSrc = try writeTempFile(name: "\(docID).txt", bytes: 16)
                try await service.saveItemFile(nodeID: nodeID, itemID: docID, sourceURL: blobSrc, fileExtension: "txt")
                if !(await service.itemFileExists(nodeID: nodeID, itemID: docID, fileExtension: "txt")) {
                    failures.append("T14: .txt blob did not appear after saveItemFile")
                }

                let blobRemoved = try await service.deleteItemFile(nodeID: nodeID, itemID: docID, fileExtension: "txt")
                if !blobRemoved { failures.append("T14: deleteItemFile returned false on present .txt blob") }
                if await service.itemFileExists(nodeID: nodeID, itemID: docID, fileExtension: "txt") {
                    failures.append("T14: .txt blob still on disk after delete")
                }

                // Phantom-thumbnail call: must not throw, must return false.
                let phantomRemoved = try await service.deleteItemFile(nodeID: nodeID, itemID: docID, fileExtension: "thumb.txt")
                if phantomRemoved { failures.append("T14: deleteItemFile returned true for never-saved thumb.txt") }
            } catch {
                failures.append("T14: threw \(error)")
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
