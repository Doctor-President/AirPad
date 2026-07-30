import Foundation
import Observation

/// On-disk record for a single conversation. Held in a single
/// `chats.json` blob alongside the user's nodes (same iCloud Drive root
/// CorpusStore uses) so chats sync with the rest of the corpus.
///
/// `title` is dumb for now — first user message truncated to ~40 chars.
/// FM-generated titles are a later step; the field exists so step 2's
/// chats-list UI can read it without a schema migration.
struct Chat: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    /// `.user` once the user renames the chat → blocks any later FM title pass
    /// from overwriting it (see `updateTitle`). nil / `.model` = FM-or-truncation
    /// authored. Optional + synthesized Codable is decode-tolerant, so chats
    /// persisted before this field decode with `titleSource == nil`.
    var titleSource: TagSource? = nil
    let createdAt: Date
    var updatedAt: Date
    var messages: [ChatSession.Message]
}

/// Persistence layer for the clean Chat lane. Mirrors the
/// `CorpusStore` ↔ `iCloudDriveService` shape: a `@MainActor` observable
/// store delegates I/O to a private `iCloudDriveService` instance whose
/// `setup()` resolves the iCloud Drive container (or local Documents
/// fallback) the first time it's read.
///
/// One file, one upsert-replace by `id`. No debounce — saves fire at
/// turn boundaries (end of `ChatSession.send`, `ChatSession.reset`,
/// scene-phase background) which is already coarse enough.
@MainActor
@Observable
final class ChatStore {

    /// Sorted by `updatedAt` desc — most recent first. Step 2's
    /// chats-list UI consumes this directly.
    private(set) var chats: [Chat] = []

    @ObservationIgnored
    private let service = iCloudDriveService()
    @ObservationIgnored
    private var didSetup = false

    /// Process-scoped deleted-id set. A live `ChatSession` may still hold
    /// the id of a chat that was just deleted from the list; its next
    /// flush (send / reset / scene-background) would otherwise hit the
    /// insert branch of `upsert` and resurrect the chat. Tombstones
    /// short-circuit `upsert` so a lagging flush is a no-op. In-memory
    /// only — across relaunch the chat is already absent from disk, so
    /// nothing to persist. Ids are fresh UUIDs, so no risk of a future
    /// genuine chat colliding with a tombstoned id.
    @ObservationIgnored
    private var tombstones: Set<UUID> = []

    /// Lazy bootstrap. Keeps `init()` synchronous so AppRouter can build
    /// the store eagerly; the actual iCloud lookup + load runs the first
    /// time anyone calls `loadIfNeeded` (ChatView.task) or `save()`.
    func loadIfNeeded() async {
        guard !didSetup else { return }
        await service.setup()
        let available = await service.isAvailable
        guard available else {
            // No storage backend wired up — leave `chats` empty and mark
            // setup done so we don't re-try every appearance.
            didSetup = true
            return
        }
        do {
            let loaded = (try await service.loadChats()) ?? []
            chats = loaded.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            print("[ChatStore] load error: \(error)")
            chats = []
        }
        didSetup = true
    }

    /// Insert-or-update by id. `title` is owned solely by
    /// `updateTitle(id:title:)` once a chat exists in the store — the
    /// existing-id path here preserves the stored title and only
    /// refreshes the transcript + `updatedAt`. Without this guard a
    /// lagging detached flush would overwrite a freshly-arrived FM
    /// title with the truncation fallback ("title revert" race). The
    /// insert path still seeds title from the incoming record so a
    /// brand-new chat never appears with a blank title.
    func upsert(_ chat: Chat) {
        // Tombstone guard: a lagging flush from a still-live session
        // whose chat the user just deleted must not re-insert it. Sits
        // ABOVE the existing-id / new-id branch so neither path can
        // resurrect a deleted id.
        if tombstones.contains(chat.id) { return }
        if let i = chats.firstIndex(where: { $0.id == chat.id }) {
            var updated = chats[i]
            updated.messages = chat.messages
            updated.updatedAt = chat.updatedAt
            chats[i] = updated
        } else {
            chats.append(chat)
        }
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    func mostRecent() -> Chat? { chats.first }

    /// Late-arriving title write — the FM title generation in
    /// `ChatSession` runs in a detached background Task after the first
    /// assistant turn commits, so by the time it lands the chat is
    /// already in the store under its truncation-fallback title. Find
    /// by id, swap the title, bump `updatedAt`, re-sort, persist.
    /// No-op when the chat has been deleted in the meantime.
    func updateTitle(id: UUID, title: String) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        // Never overwrite a user-authored title (hybrid authorship: the model
        // proposes, the human overrides — a rename wins over any later FM pass).
        guard chats[i].titleSource != .user else { return }
        chats[i].title = title
        chats[i].updatedAt = Date()
        chats.sort { $0.updatedAt > $1.updatedAt }
        Task { await save() }
    }

    /// User rename. Marks the title `.user` so no later FM title pass overwrites
    /// it. Does NOT bump `updatedAt` — a rename is metadata, not activity, so the
    /// chat keeps its place in the recency-sorted list rather than jumping to top.
    func renameChat(id: UUID, title: String) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].title = title
        chats[i].titleSource = .user
        Task { await save() }
    }

    /// Used by step 2's chats-list swipe-delete. Persists immediately —
    /// deletes are user-visible and shouldn't wait for a coalesced flush.
    /// Tombstones the id so any in-flight flush from a still-live
    /// `ChatSession` holding the same id can't resurrect it via `upsert`.
    func delete(id: UUID) {
        chats.removeAll { $0.id == id }
        tombstones.insert(id)
        Task { await save() }
    }

    /// Persist the current `chats` array. Safe to call before
    /// `loadIfNeeded` — bootstraps storage on first use.
    func save() async {
        if !didSetup { await loadIfNeeded() }
        do {
            try await service.saveChats(chats)
        } catch {
            print("[ChatStore] save error: \(error)")
        }
    }
}
