import Foundation

/// SB126 Stage 2 — central registry for runtime feature flags.
///
/// Flags are UserDefaults-backed Bools without UI. Flip via debugger
/// (`UserDefaults.standard.set(true, forKey: "ff.useCorpusAwareTagging")`)
/// or by editing the default below during validation. Adding a new flag
/// here keeps the magic-string surface in one file.
enum FeatureFlags {
    private static let useCorpusAwareTaggingKey = "ff.useCorpusAwareTagging"

    /// SB126 Stage 2 — when true, `processNodeWithAI` runs the corpus-aware
    /// path (deterministic neighborhood prefilter + corpus-context FM call).
    /// When false, the legacy `AIService.processNode` path runs unchanged.
    /// Default off; flipped on for instrumented validation only.
    static var useCorpusAwareTagging: Bool {
        get { UserDefaults.standard.bool(forKey: useCorpusAwareTaggingKey) }
        set { UserDefaults.standard.set(newValue, forKey: useCorpusAwareTaggingKey) }
    }
}
