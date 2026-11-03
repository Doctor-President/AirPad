import Foundation

/// 1.1-C fix-up (3) — a folder the user picked in Files (e.g. their Obsidian vault in iCloud Drive or On My iPhone),
/// remembered as a security-scoped bookmark under `key` so AirPad can write into it again on later launches. Reusable on
/// purpose: Export's "Save to folder…" is the first user; the 1.2 sidecar mirror is meant to sit on the same mechanism
/// (one key per use).
struct PickedFolder {
    let key: String
    private var defaults: UserDefaults { .standard }

    /// The remembered folder, or nil (never picked, or the bookmark no longer resolves — e.g. the folder was deleted).
    /// A stale bookmark is refreshed in place.
    var url: URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale { try? remember(url) }
        return url
    }

    /// The folder's name as Files shows it.
    var name: String? { url.map { FileManager.default.displayName(atPath: $0.path) } }

    /// Remember a folder the document picker returned.
    func remember(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defaults.set(try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: key)
    }

    func forget() { defaults.removeObject(forKey: key) }

    /// Run `body` with write access to the folder: inside its security scope and a coordinated write, so a cloud
    /// provider (iCloud Drive) sees the change.
    static func write<T>(into folder: URL, _ body: (URL) throws -> T) throws -> T {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var result: Result<T, Error>?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: [.forMerging], error: &coordError) { dir in
            result = Result { try body(dir) }
        }
        if let coordError { throw coordError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    /// `stem.ext`, or `stem 2.ext`, `stem 3.ext`… — the first name `taken` doesn't claim. Never overwrites silently.
    static func freeName(_ stem: String, ext: String, taken: (String) -> Bool) -> String {
        func n(_ s: String) -> String { ext.isEmpty ? s : s + "." + ext }
        var name = n(stem), k = 2
        while taken(name) { name = n("\(stem) \(k)"); k += 1 }
        return name
    }
}
