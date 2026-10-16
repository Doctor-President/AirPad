import Foundation

/// live-19 (2) — the `NodeItem` the share extension stages for a shared IMAGE, in one place so the share-import matrix
/// (`-CGShareImportMatrix`) stages exactly what the extension does. Compiled into the app and the share extension
/// (`AirPad/Models`).
enum ShareImportItems {
    /// A shared image saved at `items/<itemID>.<ext>` in the inbox node.
    /// Its own name rides along (the provider's `suggestedName`, else the vended file's — nil when both are machine-made).
    static func imageItem(itemID: String, ext: String, suggestedName: String?, sourceURL: URL?, now: Date) -> NodeItem {
        var item = NodeItem(
            id: itemID, type: .image, createdAt: now, content: nil, file: "items/\(itemID).\(ext)",
            description: nil, transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil
        )
        item.originalName = DocumentNaming.realName(suggested: suggestedName, url: sourceURL)
        return item
    }
}
