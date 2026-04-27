import Foundation
import Observation

/// Observable store for quarantined entries.
/// Provides reactive updates when entries are added, removed, or expired.
@Observable
@MainActor
final class QuarantineStore {

    var entries: [BatchParser.QuarantinedEntry] = []

    /// Adds a quarantined entry to the store.
    func add(_ entry: BatchParser.QuarantinedEntry) {
        entries.append(entry)
    }

    /// Removes a specific entry by matching rawText and importedAt.
    func remove(_ entry: BatchParser.QuarantinedEntry) {
        entries.removeAll { $0.rawText == entry.rawText && $0.importedAt == entry.importedAt }
    }

    /// Removes entries older than 48 hours.
    func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
        entries.removeAll { $0.importedAt < cutoff }
    }

    /// Removes all entries.
    func clear() {
        entries.removeAll()
    }
}
