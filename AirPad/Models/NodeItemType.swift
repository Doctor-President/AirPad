import Foundation

enum NodeItemType: String, Codable, Equatable {
    case text
    case image
    case audio
    case video
    case link
    case document
    /// Stage 4.2 — unified image/video entry holding an ordered `mediaItems`
    /// array. Existing `.image` and `.video` entries are converted on first
    /// open by `migrateEntrySchemaV1ToV2`. New entries created post-4.2 always
    /// use this case; the bare `.image` and `.video` cases are preserved only
    /// to decode pre-migration JSON. Raw value is snake_case for JSON parity
    /// with the existing CodingKey conventions on `NodeItem` and `Node`.
    case imageVideo = "image_video"
}

extension NodeItemType {
    /// Stage 3.1a — base display name an entry of this type defaults to before
    /// per-node sequential numbering is applied (`Voice`, `Voice 2`, …). The
    /// user-facing word for `.audio` is `Voice`, matching the existing capture
    /// surface vocabulary (`VoiceCaptureSheet`, `VoiceWaveformPlayer`).
    ///
    /// `.imageVideo` returns `"Image/Video"` as a generic fallback only — the
    /// 4.2 creation flow sets the actual name from item context (`Image` for
    /// a single image, `Video` for a single video, `Gallery` on transition to
    /// multi-item). This enum value is the safety net for any path that asks
    /// for a default without that context (currently none in commit 1).
    var defaultDisplayName: String {
        switch self {
        case .text:       return "Text"
        case .image:      return "Image"
        case .audio:      return "Voice"
        case .video:      return "Video"
        case .link:       return "Link"
        case .document:   return "Document"
        case .imageVideo: return "Image/Video"
        }
    }
}
