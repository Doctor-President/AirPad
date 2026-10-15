import Foundation

/// live-14 — what the detail header showed for an entry with a hero image, in order: "loading" (the band without the
/// glass), "image", or "failed" (the image can't be loaded: the same band, still no glass). DEBUG builds print one line per state so the
/// `HeroHeaderFlash` UI test (run with `-StdoutToFile`) can assert the glass never comes before the hero. Release: no-op.
enum HeroHeaderProbe {
    static func note(_ nodeID: String, _ state: String) {
        #if DEBUG
        print("[HeroHeader] node=\(nodeID) state=\(state)")
        #endif
    }
}
