import Foundation

/// SB126 Stage 2 — central registry for runtime feature flags.
///
/// Flags are UserDefaults-backed Bools without UI. Flip via debugger
/// (`UserDefaults.standard.set(true, forKey: "ff.useCorpusAwareTagging")`)
/// or by editing the default below during validation. Adding a new flag
/// here keeps the magic-string surface in one file.
enum FeatureFlags {
    private static let useCorpusAwareTaggingKey = "ff.useCorpusAwareTagging"
    private static let substrateOnCaptureKey = "ff.substrateOnCapture"

    /// SB126 Stage 2 — when true, `processNodeWithAI` runs the corpus-aware
    /// path (deterministic neighborhood prefilter + corpus-context FM call).
    /// When false, the legacy `AIService.processNode` path runs unchanged.
    /// Default off; flipped on for instrumented validation only.
    static var useCorpusAwareTagging: Bool {
        get { UserDefaults.standard.bool(forKey: useCorpusAwareTaggingKey) }
        set { UserDefaults.standard.set(newValue, forKey: useCorpusAwareTaggingKey) }
    }

    /// SB139 Stage 1 — when true, new-node capture runs the substrate FM call
    /// + `NLContextualEmbedding` after the existing tag pipeline. When false,
    /// substrate only fills in via the manual backfill control.
    /// Defaults TRUE so the substrate accumulates on every fresh capture once
    /// Stage 1 ships; flip false to isolate the tag pipeline for debugging.
    static var substrateOnCapture: Bool {
        get {
            if UserDefaults.standard.object(forKey: substrateOnCaptureKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: substrateOnCaptureKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: substrateOnCaptureKey) }
    }
}
