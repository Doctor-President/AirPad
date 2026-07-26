import Foundation
import KokoroSwift

/// Display metadata + G2P language for Kokoro-82M's voice styles. The sampler
/// enumerates the ids ACTUALLY present in the loaded `voices.npz` (so 28 vs 54
/// never drifts from a hardcoded list); this catalog just prettifies known ids
/// and picks the right English G2P for each.
///
/// KokoroSwift's Misaki G2P here supports en-US and en-GB only, so the
/// meaningful set is the English voices: `af_`/`am_` (American) and
/// `bf_`/`bm_` (British). Any non-English voice in the file is still listed
/// (raw id) but will be phonemized as en-US — expect mispronunciation.
enum KokoroVoiceCatalog {

    /// British voices use en-GB; everything else defaults to en-US.
    static func language(for id: String) -> Language {
        (id.hasPrefix("bf_") || id.hasPrefix("bm_")) ? .enGB : .enUS
    }

    /// "US · Female" etc., from the id prefix. "—" for unknown/non-English.
    static func accentTag(for id: String) -> String {
        switch true {
        case id.hasPrefix("af_"): return "US · Female"
        case id.hasPrefix("am_"): return "US · Male"
        case id.hasPrefix("bf_"): return "UK · Female"
        case id.hasPrefix("bm_"): return "UK · Male"
        default:                  return "—"
        }
    }

    /// Human name for known ids ("af_bella" → "Bella"); otherwise the id with
    /// its prefix stripped and capitalized ("xx_foo" → "Foo").
    static func displayName(for id: String) -> String {
        if let known = knownNames[id] { return known }
        let stem = id.split(separator: "_").last.map(String.init) ?? id
        return stem.prefix(1).uppercased() + stem.dropFirst()
    }

    /// Whether an id is one KokoroSwift can pronounce well (English set).
    static func isEnglish(_ id: String) -> Bool {
        ["af_", "am_", "bf_", "bm_"].contains { id.hasPrefix($0) }
    }

    /// Sort: American female, American male, British female, British male, then
    /// any non-English — each group alphabetical. Keeps the sampler readable.
    static func sorted(_ ids: [String]) -> [String] {
        func rank(_ id: String) -> Int {
            if id.hasPrefix("af_") { return 0 }
            if id.hasPrefix("am_") { return 1 }
            if id.hasPrefix("bf_") { return 2 }
            if id.hasPrefix("bm_") { return 3 }
            return 4
        }
        return ids.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a < b
        }
    }

    /// The standard Kokoro-82M v1.0 English voice ids → given names.
    private static let knownNames: [String: String] = [
        // American female
        "af_heart": "Heart", "af_alloy": "Alloy", "af_aoede": "Aoede",
        "af_bella": "Bella", "af_jessica": "Jessica", "af_kore": "Kore",
        "af_nicole": "Nicole", "af_nova": "Nova", "af_river": "River",
        "af_sarah": "Sarah", "af_sky": "Sky",
        // American male
        "am_adam": "Adam", "am_echo": "Echo", "am_eric": "Eric",
        "am_fenrir": "Fenrir", "am_liam": "Liam", "am_michael": "Michael",
        "am_onyx": "Onyx", "am_puck": "Puck", "am_santa": "Santa",
        // British female
        "bf_alice": "Alice", "bf_emma": "Emma", "bf_isabella": "Isabella",
        "bf_lily": "Lily",
        // British male
        "bm_daniel": "Daniel", "bm_fable": "Fable", "bm_george": "George",
        "bm_lewis": "Lewis",
    ]
}
