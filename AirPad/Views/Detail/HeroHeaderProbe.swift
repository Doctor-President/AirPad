import Foundation

/// live-14/16 — what the detail screen RENDERED for an entry with photos, in order, one line per state as each first
/// appears: the hero header — "loading" (the band without the glass), "image", or "failed" (the image can't be loaded:
/// the same band, still no glass) — and each gallery tile — "image" or "placeholder". The `HeroHeaderFlash` UI test
/// (run with `-HeroHeaderProbe -StdoutToFile`) asserts the FIRST state is the image. DEBUG + launch arg only; Release:
/// no-op.
enum HeroHeaderProbe {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-HeroHeaderProbe")
    #endif

    static func note(_ nodeID: String, _ state: String) {
        #if DEBUG
        if enabled { print("[HeroHeader] node=\(nodeID) state=\(state)") }
        #endif
    }

    static func tile(_ nodeID: String, _ itemID: String, _ state: String) {
        #if DEBUG
        if enabled { print("[GalleryTile] node=\(nodeID) item=\(itemID) state=\(state)") }
        #endif
    }
}
