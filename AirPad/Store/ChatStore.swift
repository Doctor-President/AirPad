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

    /// Replace-by-id or append. Re-sorts so callers reading `chats` see
    /// the freshly-updated chat at the top.
    func upsert(_ chat: Chat) {
        if let i = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[i] = chat
        } else {
            chats.append(chat)
        }
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    func mostRecent() -> Chat? { chats.first }

    /// Used by step 2's chats-list swipe-delete. Persists immediately —
    /// deletes are user-visible and shouldn't wait for a coalesced flush.
    func delete(id: UUID) {
        chats.removeAll { $0.id == id }
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
